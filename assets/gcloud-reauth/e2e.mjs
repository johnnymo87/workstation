import puppeteer from 'puppeteer-core';
import fs from 'fs';
import { newBackgroundPage } from './bg-page.mjs';

const url = fs.readFileSync(process.argv[2], 'utf8').trim();

// ---------------------------------------------------------------------------
// The auth URL arrives from the REMOTE host, so treat it as untrusted input.
//
// This is the residual hole in "invert the direction". Removing the reverse CDP
// forward stops the remote host from driving this browser directly -- but this
// flow still reads a URL out of that host's output and navigates a browser
// holding a live SSO session to it. A compromised remote could emit any URL and
// have an authenticated browser fetch it, then read a value back out. That is
// the same capability, one indirection removed.
//
// So: exact-match host, path and client_id against what the gcloud login being
// driven must produce. Anything else refuses to navigate. Compare parsed
// components, never substrings -- the same rule the authcode check below exists
// for.
//
// Pinning the client is NOT enough on its own, because this harness auto-clicks
// consent. A compromised remote can reuse gcloud's own (public) client_id with
// its own PKCE verifier and simply ASK FOR MORE -- add Gmail, Drive or directory
// scopes and the consent screen we click through grants them for your identity.
// So the scope set is an allowlist too: exactly what gcloud requests, nothing
// added.
//
// TWO PROFILES, CHOSEN BY THE CALLER, NEVER INFERRED FROM THE URL. The CLI
// login and the Application Default Credentials login use different public
// OAuth clients, redirect pages and scope sets. Selecting the profile by
// looking at the URL would let the remote pick which allowlist it is checked
// against -- and would make each allowlist the union of both. REAUTH_FLOW is
// set by refresh.sh for the login IT started; an unset or unknown value refuses.
// ---------------------------------------------------------------------------
const ALLOWED_AUTH_HOST = 'accounts.google.com';
const ALLOWED_AUTH_PATH = '/o/oauth2/auth';
const PROFILES = {
  // `gcloud auth login`. Client and redirect observed 2026-09-17, scopes
  // 2026-09-18, gcloud 537.0.0. The well-known public gcloud CLI client.
  cli: {
    clientId: '32555940559.apps.googleusercontent.com',
    redirectUri: 'https://sdk.cloud.google.com/authcode.html',
    scopes: new Set([
      'openid',
      'https://www.googleapis.com/auth/userinfo.email',
      'https://www.googleapis.com/auth/cloud-platform',
      'https://www.googleapis.com/auth/appengine.admin',
      'https://www.googleapis.com/auth/sqlservice.login',
      'https://www.googleapis.com/auth/compute',
      'https://www.googleapis.com/auth/accounts.reauth',
    ]),
  },
  // `gcloud auth application-default login`. All three observed 2026-10-15 from
  // gcloud 537.0.0 on the remote host. The well-known public gcloud ADC client,
  // identical for every install.
  adc: {
    clientId: '764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com',
    redirectUri: 'https://sdk.cloud.google.com/applicationdefaultauthcode.html',
    scopes: new Set([
      'openid',
      'https://www.googleapis.com/auth/userinfo.email',
      'https://www.googleapis.com/auth/cloud-platform',
      'https://www.googleapis.com/auth/sqlservice.login',
    ]),
  },
};

const FLOW = process.env.REAUTH_FLOW;
if (!Object.hasOwn(PROFILES, FLOW ?? '')) {
  // Exit 4 (not 3): this is the caller's misconfiguration, not a hostile URL.
  console.error(`REFUSING: REAUTH_FLOW must be one of ${Object.keys(PROFILES).join('|')}, got ${JSON.stringify(FLOW)}`);
  process.exit(4);
}
const PROFILE = PROFILES[FLOW];
const ALLOWED_CLIENT_ID = PROFILE.clientId;
const ALLOWED_REDIRECT_URI = PROFILE.redirectUri;
const ALLOWED_SCOPES = PROFILE.scopes;
const AUTHCODE_PAGE = new URL(ALLOWED_REDIRECT_URI);

const validateAuthUrl = (raw) => {
  let u;
  try { u = new URL(raw); } catch { return 'unparseable URL'; }
  if (u.protocol !== 'https:') return `refusing non-https scheme ${u.protocol}`;
  if (u.host !== ALLOWED_AUTH_HOST) return `refusing unexpected host ${u.host}`;
  if (u.pathname !== ALLOWED_AUTH_PATH) return `refusing unexpected path ${u.pathname}`;

  // A repeated parameter lets a caller show us one value and the server another,
  // depending on whose precedence rule wins. Rather than depend on Google's
  // (undocumented, unverified here), refuse any duplicate of a pinned key.
  for (const k of ['client_id', 'redirect_uri', 'response_type', 'scope', 'code_challenge_method']) {
    if (u.searchParams.getAll(k).length > 1) return `refusing duplicated ${k} parameter`;
  }

  const cid = u.searchParams.get('client_id');
  if (cid !== ALLOWED_CLIENT_ID) return `refusing unexpected client_id ${cid}`;
  const redir = u.searchParams.get('redirect_uri');
  if (redir !== ALLOWED_REDIRECT_URI) return `refusing unexpected redirect_uri ${redir}`;
  if (u.searchParams.get('response_type') !== 'code') return 'refusing non-code response_type';
  if (u.searchParams.get('code_challenge_method') !== 'S256') return 'refusing non-S256 PKCE method';

  const scopes = (u.searchParams.get('scope') || '').split(/\s+/).filter(Boolean);
  if (scopes.length === 0) return 'refusing URL with no scopes';
  const extra = scopes.filter((s) => !ALLOWED_SCOPES.has(s));
  if (extra.length) return `refusing escalated scope(s): ${extra.join(', ')}`;
  return null;
};

const urlRejection = validateAuthUrl(url);

const OUT = process.env.REAUTH_SHOTS
  || `${process.env.HOME}/.local/state/gcloud-reauth/shots`;
fs.mkdirSync(OUT, { recursive: true });
const WORK = process.env.REAUTH_WORKDIR || `${process.env.HOME}/.local/state/gcloud-reauth/run`;
const CODE_FILE = `${WORK}/authcode.txt`;
const CDP_URL = process.env.REAUTH_CDP_URL || 'http://127.0.0.1:9223';
// IdP host comes from the environment; no vendor hostname in a public file.
const IDP_HOST_RE = process.env.IDP_ORIGIN
  ? new RegExp(new URL(process.env.IDP_ORIGIN).host.replace(/\./g, '\\.'), 'i')
  : /(?!)/;
const ACCT = process.env.SPIKE_ACCOUNT;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The IdP redirect carries the OAuth continue/RelayState in its query string,
// which CONTAINS the literal redirect URI (e.g. 'sdk.cloud.google.com/authcode').
// A substring test therefore reports "we reached the authcode page" while
// sitting on The IdP's login form. Compare host and path, never the whole URL --
// and compare them to THIS flow's pinned redirect URI exactly, so the CLI and
// ADC code pages cannot stand in for each other.
const onAuthcode = (u) => {
  try {
    const x = new URL(u);
    return x.protocol === 'https:' && x.host === AUTHCODE_PAGE.host && x.pathname === AUTHCODE_PAGE.pathname;
  } catch { return false; }
};
const t0 = Date.now();
const log = (...a) => console.log(`[+${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...a);

// protocolTimeout well under the wrapper's 300s budget, so a stall surfaces as
// a logged error rather than being killed mid-write by the outer timeout.
// NOTE ON FOCUS: pages are created in the BACKGROUND (bg-page.mjs), so a
// refresh never raises Chrome over whatever the human is doing. An earlier
// measurement (2026-09) found background targets hanging on this flow; that no
// longer holds -- re-measured 2026-10-22: both the CLI and ADC logins completed
// in background tabs, and the frontmost app never changed for the whole run
// (sampled every 0.5s). The page mode is recorded in every result row, so a
// fall back to a foreground page shows up in reauth-probe.jsonl.
if (urlRejection) {
  // Refuse BEFORE connecting to the browser -- a rejected URL must not so much
  // as open a tab in a profile holding a live session.
  const row = {
    ts: new Date().toISOString(), probe: 'browser_e2e', flow: FLOW, outcome: 'url_rejected',
    url_rejected_reason: urlRejection, awaiting_human: false,
  };
  const LOG = process.env.GCLOUD_REAUTH_PROBE_LOG
    || `${process.env.HOME}/.local/state/gcloud-reauth/reauth-probe.jsonl`;
  fs.mkdirSync(LOG.replace(/\/[^/]+$/, ''), { recursive: true });
  fs.appendFileSync(LOG, JSON.stringify(row) + '\n');
  fs.mkdirSync(WORK, { recursive: true });
  fs.writeFileSync(`${WORK}/e2e-result.json`, JSON.stringify(row));
  console.error(`REFUSING TO NAVIGATE: ${urlRejection}`);
  console.log('RESULT:', JSON.stringify(row));
  process.exit(3);
}

const browser = await puppeteer.connect({ browserURL: CDP_URL, defaultViewport: null, protocolTimeout: 90000 });
for (const p of await browser.pages()) {
  // Also clears an IdP login tab left open by a previous run (see the
  // human-handoff branch below), so these cannot accumulate.
  if (p.url().includes('accounts.google.com')
      || (IDP_HOST_RE.source !== '(?!)' && IDP_HOST_RE.test(p.url()))) {
    try { await p.close(); } catch {}
  }
}
const { page, mode: pageMode } = await newBackgroundPage(browser);
log('page mode', pageMode);
const bodyText = async () => {
  // A page-level evaluate can also land mid-navigation; one retry after the
  // new document settles covers it.
  for (let i = 0; ; i++) {
    try { return (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, ' '); }
    catch (e) { if (i >= 1) throw e; await sleep(2000); }
  }
};

let handoffToHuman = false;
const result = {
  ts: new Date().toISOString(),
  flow: FLOW,
  completed_on_cookies: false,
  password_demanded: false,
  mfa_demanded: false,
  captcha: false,
  bot_blocked: false,
  idp_redirect: false,
  idp_login_required: false,
  awaiting_human: false,
  clicks: [],
  outcome: null,
  page_mode: pageMode,
};

// Element handles die when the page navigates under them -- and these pages
// redirect on their own for a while after each click. Using a stale handle
// throws "Argument should belong to the same JavaScript world as target
// object" (or "Execution context was destroyed"), which used to abort the whole
// flow as outcome `error`: 3 of 33 runs by 2026-10-15. Treat a dead handle as
// "not this one" and move on; the loops re-query on their next pass.
const textOf = async (h) => {
  try { return ((await h.evaluate((e) => e.innerText || '')) || ''); } catch { return ''; }
};
// page.$$ itself can land mid-navigation too (2026-10-16: an IdP login page
// redirecting under the account-chooser query). No elements found is the
// honest answer for a page that is going away.
const queryAll = async (sel) => {
  try { return await page.$$(sel); } catch { return []; }
};
const clickByText = async (patterns) => {
  const hs = await queryAll('button, div[role="button"], li, div[role="link"], span[jsname]');
  for (const h of hs) {
    const t = (await textOf(h)).trim();
    if (patterns.some((p) => p.test(t))) {
      try { await h.click(); return t.replace(/\s+/g, ' ').slice(0, 60); } catch {}
    }
  }
  return null;
};

const inspect = async (label) => {
  const txt = await bodyText();
  const u = page.url();
  if (/type the text you hear or see/i.test(txt)) result.captcha = true;
  if (/browser or app may not be secure/i.test(txt)) result.bot_blocked = true;
  if (/enter your password|show password|forgot password/i.test(txt)) result.password_demanded = true;
  // NOTE: do NOT match a bare /verification code/ -- gcloud's own authcode page says
  // "Enter the following verification code in gcloud CLI", which is the CLI code, not MFA.
  const onAuthcodePage = onAuthcode(u);
  if (!onAuthcodePage && /verify it.s you|2-step verification|google authenticator|tap yes|security key|use your passkey|enter the code sent/i.test(txt)) result.mfa_demanded = true;
  if (IDP_HOST_RE.test(u) || /\/sso\/saml|SAMLRequest/i.test(u)) result.idp_redirect = true;
  // The IdP's own sign-in form. Many IdPs are identifier-first: the first screen says
  // "Username" and never the word "password", so the generic password regex
  // above does NOT catch it. This is a credential prompt and must halt.
  if (result.idp_redirect && /sign in with your account|^username$|unlock account\?/im.test(txt)) {
    result.idp_login_required = true;
  }
  log(label, '|', u.slice(0, 90), '|', txt.slice(0, 180));
  await page.screenshot({ path: `${OUT}/e2e-${label}.png` });
  return { txt, u };
};

try {
  await page.goto(url, { waitUntil: 'networkidle2', timeout: 60000 });
  await sleep(3000);
  await inspect('01-landing');

  // Step: account chooser
  const hs = await queryAll('li, div[role="link"], div[data-identifier]');
  for (const h of hs) {
    const t = await textOf(h);
    if (t.includes(ACCT)) {
      try { await h.click(); result.clicks.push('account-row'); break; } catch {}
    }
  }
  await sleep(6000);
  await inspect('02-after-account');

  // Up to 4 consent-ish screens: "Continue" / "Allow" / "Select all"
  for (let i = 0; i < 4; i++) {
    if (onAuthcode(page.url())) break;
    const { txt } = await inspect(`03-loop${i}`);
    if (result.password_demanded || result.mfa_demanded || result.captcha || result.bot_blocked || result.idp_login_required) {
      log('HALT: challenge detected, refusing to proceed');
      // A human has to act. The tab stays open, still in the background; the
      // alert refresh.sh raises asks for attention, and its button brings this
      // tab forward. Focus moves only when the human says so.
      handoffToHuman = true;
      result.awaiting_human = true;
      break;
    }
    await clickByText([/^select all$/i]);
    const c = await clickByText([/^continue$/i, /^allow$/i, /^next$/i]);
    if (!c) { log(`no actionable button on loop${i}`); break; }
    result.clicks.push(c);
    await sleep(6000);
  }

  const { txt, u } = await inspect('04-final');
  if (onAuthcode(u)) {
    const code = await page.evaluate(() => {
      const el = document.querySelector('#code, input[readonly], textarea');
      return el ? (el.value || el.textContent) : null;
    });
    const m = code || (txt.match(/4\/[A-Za-z0-9_\-]{20,}/) || [])[0];
    if (m) {
      fs.writeFileSync(CODE_FILE, m.trim());
      result.completed_on_cookies = !result.password_demanded && !result.mfa_demanded;
      result.outcome = 'authcode_obtained';
      log('AUTHCODE OBTAINED, length', m.trim().length);
    } else {
      result.outcome = 'authcode_page_no_code';
    }
  } else if (result.idp_login_required) result.outcome = 'idp_login_required';
  else if (result.password_demanded) result.outcome = 'password_demanded';
  else if (result.mfa_demanded) result.outcome = 'mfa_demanded';
  else if (result.captcha || result.bot_blocked) result.outcome = 'bot_blocked';
  else result.outcome = 'stalled';
} catch (e) {
  result.error = e.message;
  log('ERROR', e.stack || e.message);
  // A credential prompt seen BEFORE the crash is still the answer: a human has
  // to sign in. Reporting `error` instead sent refresh.sh down its 2h
  // non-human backoff on 2026-10-16, rather than raising the page and waiting
  // for the sign-in. Same precedence as the normal path above.
  const challenge = result.idp_login_required ? 'idp_login_required'
    : result.password_demanded ? 'password_demanded'
    : result.mfa_demanded ? 'mfa_demanded'
    : (result.captcha || result.bot_blocked) ? 'bot_blocked'
    : null;
  if (challenge) {
    result.outcome = challenge;
    handoffToHuman = true;
    result.awaiting_human = true;
  } else {
    result.outcome = 'error';
  }
} finally {
  console.log('RESULT:', JSON.stringify(result));
  const LOG = process.env.GCLOUD_REAUTH_PROBE_LOG
    || `${process.env.HOME}/.local/state/gcloud-reauth/reauth-probe.jsonl`;
  fs.mkdirSync(LOG.replace(/\/[^/]+$/, ''), { recursive: true });
  fs.appendFileSync(LOG, JSON.stringify({
    ts: result.ts,
    account: process.env.SPIKE_ACCOUNT ?? null,
    probe: 'browser_e2e',
    flow: FLOW,
    token_ok: null,
    reauth_required: null,
    completed_on_cookies: result.completed_on_cookies,
    password_demanded: result.password_demanded,
    mfa_demanded: result.mfa_demanded,
    captcha: result.captcha,
    bot_blocked: result.bot_blocked,
    idp_redirect: result.idp_redirect,
    idp_login_required: result.idp_login_required,
    awaiting_human: result.awaiting_human,
    clicks: result.clicks,
    outcome: result.outcome,
    page_mode: result.page_mode,
  }) + '\n');
  fs.writeFileSync(`${WORK}/e2e-result.json`, JSON.stringify(result));
  if (handoffToHuman) {
    // Left open, NOT raised: the alert's "Open sign-in page" button raises it
    // (raise-signin.mjs finds this tab), so focus moves only when the human
    // asks for it.
    console.log('HANDOFF: left the sign-in page open in the background for the human');
  } else {
    try { await page.close(); } catch {}
  }
  browser.disconnect();
}
