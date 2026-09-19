// Open a page WITHOUT stealing focus.
//
// browser.newPage() creates a foreground target, which raises the Chrome window
// and steals focus on the Mac -- unacceptable for something that fires on a
// timer while the human is working. Target.createTarget supports background:
// true, which puppeteer's newPage() does not expose.
//
// SCOPE: this is for the IdP session PROBE, which loads one tiny page
// (<origin>/favicon.ico) and issues one fetch. It is deliberately NOT used by
// e2e.mjs -- background targets were measured against a real OAuth page there
// and failed (target.page() hangs in page.evaluate, or 'Session with given id
// not found'); see the focus note in e2e.mjs. The two differ in both page
// weight and cadence: e2e runs ~once a day when a reauth is actually due, so a
// brief focus steal is a fair price; the probe runs every 90 minutes forever,
// so it is not.
//
// The new target is matched by a nonce in its initial URL rather than by a
// private _targetId field, so this does not depend on puppeteer internals.
// If anything in the background path fails, fall back to newPage() rather than
// failing the run: a stolen focus is worse than nothing, a missed keepalive is
// worse than a stolen focus.
// Returns { page, mode } where mode is 'background' or 'foreground'. The caller
// is expected to RECORD the mode: a silent fall back to foreground reinstates
// the exact behaviour this helper exists to prevent, and an unrecorded
// regression is indistinguishable from the fix working.
export async function newBackgroundPage(browser) {
  const nonce = `gcloud-reauth-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const initial = `about:blank#${nonce}`;
  const client = await browser.target().createCDPSession();

  let targetId;
  try {
    ({ targetId } = await client.send('Target.createTarget', { url: initial, background: true }));
  } catch {
    await client.detach().catch(() => {});
    return { page: await browser.newPage(), mode: 'foreground' };
  }

  try {
    const target = await browser.waitForTarget((t) => t.url().includes(nonce), { timeout: 15000 });
    const page = await target.page();
    if (page) {
      await client.detach().catch(() => {});
      return { page, mode: 'background' };
    }
  } catch {
    // fall through to the foreground path
  }

  // The target exists but we could not get a Page for it. Close it by id --
  // otherwise one orphan about:blank tab accumulates per failing run, forever,
  // and nothing else in this harness sweeps a tab at that URL.
  await client.send('Target.closeTarget', { targetId }).catch(() => {});
  await client.detach().catch(() => {});
  return { page: await browser.newPage(), mode: 'foreground' };
}
