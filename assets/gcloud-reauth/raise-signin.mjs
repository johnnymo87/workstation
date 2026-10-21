// Put the IdP sign-in in front of the human, in the isolated Chrome.
//
// Run when the human clicks "Open sign-in page" on the reauth alert. Reuses a
// sign-in tab the refresh already left open (an IdP or Google accounts page);
// otherwise opens the IdP origin, whose own sign-in is exactly the session the
// refresh is missing. Foreground on purpose: the human asked for it.
//
// Usage: node raise-signin.mjs
//   IDP_ORIGIN       required (from Keychain via the agent)
//   REAUTH_CDP_URL   default http://127.0.0.1:9223

import puppeteer from 'puppeteer-core';

const CDP_URL = process.env.REAUTH_CDP_URL || 'http://127.0.0.1:9223';
const ORIGIN = process.env.IDP_ORIGIN;
if (!ORIGIN) {
  console.error('IDP_ORIGIN is not set');
  process.exit(64);
}
const idpHost = new URL(ORIGIN).host;

const browser = await puppeteer.connect({ browserURL: CDP_URL, defaultViewport: null, protocolTimeout: 30000 });
try {
  let page = null;
  for (const p of await browser.pages()) {
    let host = '';
    try { host = new URL(p.url()).host; } catch {}
    if (host === idpHost || host === 'accounts.google.com') { page = p; break; }
  }
  if (!page) {
    page = await browser.newPage();
    await page.goto(ORIGIN, { waitUntil: 'domcontentloaded', timeout: 30000 });
  }
  await page.bringToFront();
  console.log(`raised ${new URL(page.url()).host}`);
} finally {
  browser.disconnect();
}
