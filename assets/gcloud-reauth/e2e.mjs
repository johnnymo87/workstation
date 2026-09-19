import puppeteer from 'puppeteer-core';
import fs from 'fs';

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
// So: exact-match host, path and client_id against what `gcloud auth login`
// must produce. Anything else refuses to navigate. Compare parsed components,
// never substrings -- the same rule the authcode check below exists for.
// Observed 2026-09-17 from gcloud 537.0.0 on the remote host. The client_id is
// the public, well-known gcloud CLI client, identical for every install.
// ---------------------------------------------------------------------------
const ALLOWED_AUTH_HOST = 'accounts.google.com';
const ALLOWED_AUTH_PATH = '/o/oauth2/auth';
const ALLOWED_CLIENT_ID = '32555940559.apps.googleusercontent.com';
const ALLOWED_REDIRECT_URI = 'https://sdk.cloud.google.com/authcode.html';

// Pinning the client is NOT enough on its own, because this harness auto-clicks
// consent. A compromised remote can reuse gcloud's own (public) client_id with
// its own PKCE verifier and simply ASK FOR MORE -- add Gmail, Drive or directory
// scopes and the consent screen we click through grants them for your identity.
// So the scope set is an allowlist too: exactly what gcloud requests, nothing
// added. Captured 2026-09-18 from gcloud 537.0.0.
const ALLOWED_SCOPES = new Set([
  'openid',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/cloud-platform',
  'https://www.googleapis.com/auth/appengine.admin',
  'https://www.googleapis.com/auth/sqlservice.login',
  'https://www.googleapis.com/auth/compute',
  'https://www.googleapis.com/auth/accounts.reauth',
]);

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
// which CONTAINS the literal 'sdk.cloud.google.com/authcode'. A substring test
// therefore reports "we reached the authcode page" while sitting on The IdP's
// login form. Compare host and path, never the whole URL.
const onAuthcode = (u) => {
  try { const x = new URL(u); return x.host === 'sdk.cloud.google.com' && x.pathname.startsWith('/authcode'); }
  catch { return false; }
};
const t0 = Date.now();
const log = (...a) => console.log(`[+${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...a);

// protocolTimeout well under the wrapper's 300s budget, so a stall surfaces as
// a logged error rather than being killed mid-write by the outer timeout.
// NOTE ON FOCUS: pages are created in the FOREGROUND. Creating them as
// background targets (Target.createTarget with background:true) was tried and
// does not work here -- target.page() either hangs in page.evaluate until
// protocolTimeout, or fails with 'Target.attachToTarget: Session with given id
// not found'. Measured side by side against a real OAuth page: foreground 1.1s
// OK, background failed. This flow runs only when a reauth is actually due
// (~once a day), so a brief focus steal is an acceptable price for a path that
// works. Do not reintroduce the background variant HERE without measuring it.
// It IS used by idp-session-probe.mjs (see bg-page.mjs): that path loads one
// static asset and runs every 90 minutes, and was measured separately. Finding
// createTarget in this tree is therefore not evidence that this note is stale.
if (urlRejection) {
  // Refuse BEFORE connecting to the browser -- a rejected URL must not so much
  // as open a tab in a profile holding a live session.
  const row = {
    ts: new Date().toISOString(), probe: 'browser_e2e', outcome: 'url_rejected',
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
const page = await browser.newPage();
const bodyText = async () => (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ');

let handoffToHuman = false;
const result = {
  ts: new Date().toISOString(),
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
};

const clickByText = async (patterns) => {
  const hs = await page.$$('button, div[role="button"], li, div[role="link"], span[jsname]');
  for (const h of hs) {
    const t = ((await h.evaluate((e) => e.innerText || '')) || '').trim();
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
  const hs = await page.$$('li, div[role="link"], div[data-identifier]');
  for (const h of hs) {
    const t = await h.evaluate((e) => e.innerText || '');
    if (t.includes(ACCT)) { await h.click(); result.clicks.push('account-row'); break; }
  }
  await sleep(6000);
  await inspect('02-after-account');

  // Up to 4 consent-ish screens: "Continue" / "Allow" / "Select all"
  for (let i = 0; i < 4; i++) {
    if (onAuthcode(page.url())) break;
    const { txt } = await inspect(`03-loop${i}`);
    if (result.password_demanded || result.mfa_demanded || result.captcha || result.bot_blocked || result.idp_login_required) {
      log('HALT: challenge detected, refusing to proceed');
      // A human has to act. Routine runs stay in a background tab so they never
      // steal focus, but this is the one case where grabbing attention IS the
      // correct behaviour -- the alternative is failing silently and being
      // discovered hours later as dead credentials.
      handoffToHuman = true;
      result.awaiting_human = true;   // set here: the log line is written before the raise
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
  result.outcome = 'error';
  log('ERROR', e.message);
} finally {
  console.log('RESULT:', JSON.stringify(result));
  const LOG = process.env.GCLOUD_REAUTH_PROBE_LOG
    || `${process.env.HOME}/.local/state/gcloud-reauth/reauth-probe.jsonl`;
  fs.mkdirSync(LOG.replace(/\/[^/]+$/, ''), { recursive: true });
  fs.appendFileSync(LOG, JSON.stringify({
    ts: result.ts,
    account: process.env.SPIKE_ACCOUNT ?? null,
    probe: 'browser_e2e',
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
  }) + '\n');
  fs.writeFileSync(`${WORK}/e2e-result.json`, JSON.stringify(result));
  if (handoffToHuman) {
    try {
      await page.bringToFront();       // raise the tab, and with it the window
      console.log('HANDOFF: left the sign-in page open and raised it for the human');
    } catch (e) {
      console.log('HANDOFF: could not raise the page:', e.message);
    }
  } else {
    try { await page.close(); } catch {}
  }
  browser.disconnect();
}
