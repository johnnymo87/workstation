// Read-only probe of the IdP session inside the isolated Chrome jar.
//
// Asks the IdP's own session endpoint how long the current session has left. This
// answers the question directly (expiresAt) rather than by waiting for it to
// die, and it never touches a credential.
//
// MEASUREMENT HAZARD: an authenticated request to the IdP resets its *idle*
// timeout. Confirmed empirically -- two reads 95s apart both reported exactly
// 7200s remaining, with expiresAt sliding forward. A frequent poll therefore
// keeps the session alive rather than observing it, and any sample taken while
// the keepalive timer is active measures the keepalive, not the policy.
//
// Usage: node idp-session-probe.mjs [idp-origin]
//   REAUTH_CDP_URL   default http://127.0.0.1:9223
//   IDP_LOG         default ~/.local/state/gcloud-reauth-spike/idp-session.jsonl

import puppeteer from 'puppeteer-core';
import fs from 'fs';
import os from 'os';

const CDP_URL = process.env.REAUTH_CDP_URL || 'http://127.0.0.1:9223';
const ORIGIN = process.argv[2] || process.env.IDP_ORIGIN;
// Session endpoint path is supplied by the environment so that no vendor-specific
// route is hardcoded in a public file.
const SESSION_PATH = process.env.IDP_SESSION_PATH;
const LOG = process.env.IDP_LOG
  || `${os.homedir()}/.local/state/gcloud-reauth-spike/idp-session.jsonl`;

if (!ORIGIN || !SESSION_PATH) {
  console.error('usage: IDP_SESSION_PATH=<path> node idp-session-probe.mjs https://<idp-origin>');
  process.exit(64);
}

const row = {
  ts: new Date().toISOString(),
  probe: 'idp_session',
  origin: ORIGIN,
  reachable: false,
  has_session: null,
  status: null,
  expires_at: null,
  seconds_remaining: null,
  login: null,
  error: null,
};

let browser;
try {
  browser = await puppeteer.connect({ browserURL: CDP_URL, defaultViewport: null });
  row.reachable = true;
  const page = await browser.newPage();
  try {
    // about:blank cannot make a same-origin credentialed request; land on the
    // origin first, then fetch. This is a GET of a read-only endpoint.
    await page.goto(`${ORIGIN}/favicon.ico`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    const res = await page.evaluate(async (o, p) => {
      const r = await fetch(`${o}${p}`, {
        credentials: 'include',
        headers: { Accept: 'application/json' },
      });
      let body = null;
      try { body = await r.json(); } catch { body = null; }
      return { status: r.status, body };
    }, ORIGIN, SESSION_PATH);

    row.status = res.status;
    if (res.status === 200 && res.body) {
      row.has_session = true;
      row.expires_at = res.body.expiresAt ?? null;
      row.login = res.body.login ?? null;
      if (row.expires_at) {
        row.seconds_remaining = Math.round((new Date(row.expires_at) - Date.now()) / 1000);
      }
    } else {
      // 404 is a common answer for "no session"; 401/403 likewise mean not signed in.
      row.has_session = false;
    }
  } finally {
    try { await page.close(); } catch {}
  }
} catch (e) {
  row.error = e.message;
} finally {
  try { browser?.disconnect(); } catch {}
}

fs.mkdirSync(LOG.replace(/\/[^/]+$/, ''), { recursive: true });
fs.appendFileSync(LOG, JSON.stringify(row) + '\n');
console.log(JSON.stringify(row, null, 1));
