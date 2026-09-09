---
name: managing-opencode-plugins
description: Use when bumping the version of an npm-published opencode plugin (e.g. @ex-machina/opencode-anthropic-auth) or debugging why a plugin upgrade didn't take effect. Covers the cache-invalidation gotcha that silently kept us on plugin v1.2.0 for weeks.
---

# Managing OpenCode Plugins

## TL;DR

OpenCode caches resolved plugins under `~/.cache/opencode/packages/` keyed by
the version spec at first-fetch time. Bumping the version pin in
`users/dev/opencode-config.nix` is necessary but **not sufficient** — without
cache invalidation, opencode-serve continues to load the old version forever.

A pin must do **two** things, and for months it only did one:

1. **Rewrite the runtime spec.** `opencodePluginPins` feeds `pluginSpecs`,
   which turns the bare names in `opencode.base.json` into `<pkg>@<version>`
   in the generated `opencode.json`. *This* is what makes opencode fetch and
   cache the pinned version.
2. **Invalidate a mismatched cache**, which the activation loop does.

Until 2026-09-09 only (2) existed. The runtime array carried bare names,
opencode normalised them to `@latest`, and the pin had **no delivery
mechanism at all** — it could not pin, and it could not downgrade. What it
did produce was *churn*: every rebuild saw `latest != pin`, purged, and
opencode immediately re-downloaded `latest`. The log line looked like an
impending downgrade and was nothing of the sort. If you are reading a
`cached at X, pinned at Y -> purging` line from before that date, that is
what it means.

The `installOpencodePlugins` activation automates both halves. If you bypass
it (manual edits, fresh clones, foreign machines), use the recipe at the
bottom of this file.

## How OpenCode Resolves Plugins

For each entry in `opencode.json`'s `plugin: [...]` array:

1. **`file://...` paths** — loaded directly from the symlink, no caching.
2. **`<scope>/<name>` npm-style names** — opencode looks in
   `~/.cache/opencode/packages/<scope>/<name>@<version-spec>/node_modules/<scope>/<name>/`
   first. If present, that copy is loaded. If absent, opencode runs
   `npm install <name>@<version-spec>` into the cache dir, THEN loads it.

The cache key is the **literal version spec** at first-fetch time, not the
resolved version. So `<name>@latest/` is created once and never re-resolved.
If the package later ships v1.8.0, the cache still holds v1.2.0.

This means opencode-serve **never reads from `~/.config/opencode/node_modules/`**
when resolving plugins. The `npm install` we run there during activation looks
like the canonical install but isn't on the resolution path. **The cache is
what actually matters.**

Why we still run `npm install`: it ensures the peer dep `@opencode-ai/plugin`
(declared in `~/.config/opencode/package.json`) is materialized at the right
version, and it's a useful sanity-check that the pinned version actually
exists on npm before we do anything destructive to the cache. Don't remove
it without thinking through both implications.

## Verifying What Version Is Actually Loaded

The canonical check is:

```bash
find ~/.cache/opencode/packages -path '*<plugin-name>/package.json' | \
  xargs -I{} jq -r '.name + " v" + .version' {}
```

For belt-and-suspenders, check what file the running process has open:

```bash
SERVE_PID=$(pgrep -f 'opencode serve' | head -1)
sudo lsof -p $SERVE_PID 2>/dev/null | grep -E 'plugin-name/dist'
```

Both should agree. If `~/.config/opencode/node_modules/` shows a different
version from `~/.cache/opencode/packages/`, the cache wins.

## How `installOpencodePlugins` Handles This

`opencodePluginPins` lives at **module scope** in
`users/dev/opencode-config.nix` (not inside the activation). Two consumers
read it:

1. **`pluginSpecs`** — rewrites `opencode.base.json`'s bare `plugin` entries
   into `<pkg>@<version>` for the generated `opencode.json`. Entries with no
   pin (e.g. `./plugins/caveman/plugin.js`) pass through untouched. Pins are
   asserted to be **exact** versions at eval time; a range or a dist-tag
   would re-create the churn described above and is rejected.
2. **The activation**, which:
   - runs ONE `npm install <pkg1>@<v1> <pkg2>@<v2> --no-save` for all pins
     (never one per package — `--no-save` prunes the previous one as
     extraneous, leaving only the last pin on disk);
   - for each pin, checks each cached copy's version and `rm -rf`s the dir
     if it doesn't match.

Log lines look like:

```
installOpencodePlugins: @ex-machina/opencode-anthropic-auth cached at 1.2.0, pinned at 1.8.0 -> purging /home/dev/.cache/opencode/packages/@ex-machina/opencode-anthropic-auth@latest
installOpencodePlugins: stale plugin cache purged. Running serves keep the OLD plugin until the pool restarts.
```

When pin == cache, no purge, no log lines (idempotent).

**The activation does not restart opencode-serve.** It prints options and
lets you choose: the nightly 03:00 `nightly-restart-background.timer` picks
it up automatically within a day, or `reset-workspace` does it now and kills
live sessions. Note that after a purge the pinned version is **not yet on
disk** — opencode re-fetches it from npm at that restart, so the restart
needs registry access.

## Adding a New Pinned Plugin

1. Add the entry to `opencode.base.json`'s `plugin: [...]` array.
2. Add the version pin to the module-scope `opencodePluginPins` attrset in
   `users/dev/opencode-config.nix` (search for `opencodePluginPins =`; it sits
   above `pluginSpecs`, NOT inside `installOpencodePlugins`):

   ```nix
   opencodePluginPins = {
     "@ex-machina/opencode-anthropic-auth" = "1.8.4";
     "your-new-plugin" = "0.3.1";  # add this — exact version, no ranges
   };
   ```

   Adding it here is what makes the runtime spec `your-new-plugin@0.3.1`.
   A bare entry in `opencode.base.json` with no pin resolves to `latest` and
   is effectively unpinned.

3. Run `nix run home-manager -- switch --flake .#$(cat /etc/hostname)`.
4. Verify with the `find ... package.json` recipe above.

## Bumping an Existing Pin

1. Check what's on npm: `npm view <plugin-name> versions --json | jq '.[-5:]'`
2. Edit the version in `opencodePluginPins`.
3. `nix run home-manager -- switch --flake .#$(cat /etc/hostname)`.
4. Watch for `installOpencodePlugins:` log lines confirming the purge. The new
   version goes live at the next pool restart, not at switch time.
5. Smoke-test by sending a request that exercises the plugin (e.g. for
   `@ex-machina/opencode-anthropic-auth`, send any anthropic-provider message
   and confirm `cost: 0` in the response — that means OAuth headers were
   injected).

## Manual Recovery (Fresh Clones, Bypass, Debugging)

If you ever need to do this by hand (e.g. on a machine that doesn't run the
home-manager activation, or when debugging):

```bash
# 1. Identify which plugin is stale
find ~/.cache/opencode/packages -name 'package.json' \
  -path '*node_modules/*/package.json' \
  ! -path '*node_modules/*/node_modules/*' \
  | xargs -I{} sh -c 'jq -r ".name + \" v\" + .version" "$1" | sed "s|^|{}: |"' _ {}

# 2. Nuke the stale cache dir
rm -rf ~/.cache/opencode/packages/<scope>/<name>@*

# 3. Restart opencode-serve so it re-fetches on next request
sudo systemctl restart opencode-serve.service

# 4. Trigger a request to repopulate cache (any request that uses the plugin)
SID=$(curl -s -X POST http://127.0.0.1:4700/session | jq -r '.id')
curl -s -X POST "http://127.0.0.1:4700/session/$SID/message" \
  -H 'Content-Type: application/json' \
  -d '{"providerID":"anthropic","modelID":"claude-opus-4-7","parts":[{"type":"text","text":"ping"}]}'

# 5. Verify the new version is now cached
find ~/.cache/opencode/packages/<scope>/<name>@* -name 'package.json' \
  -path '*node_modules/*/package.json' \
  ! -path '*node_modules/*/node_modules/*' \
  | xargs jq -r '.version'
```

## Why "Just Use `@latest`" Doesn't Save You

Even if you change the pin to `@latest` (which we don't do — pinning is a
security best practice per the plugin's README), the cache key would become
`<name>@latest/` once, and that directory would still freeze at whatever
version was current at first-fetch. The cache invalidation logic would still
have to compare cached version vs. some "expected" version. Since `@latest`
gives no expected version to compare against, you'd be stuck.

Pinning is the right call. The only requirement is that the activation
purges the cache when the pin changes — which is exactly what we do.

## History

- **2026-04-30**: Discovered the gotcha. The pin had been bumped from
  `1.2.0` (Apr 8) → `1.6.1` → `1.8.0` over the course of weeks, but cloudbox
  was still loading `1.2.0` from the cache the entire time. The previous
  activation only ran `npm install` into `node_modules/` and never touched
  the cache. Confirmed via `lsof` on the running opencode-serve process.

## Related

- Plugin README: `~/.config/opencode/node_modules/@ex-machina/opencode-anthropic-auth/README.md`
  has the security rationale for pinning ("nefarious updates").
- `users/dev/opencode-config.nix:installOpencodePlugins` — the activation.
- `assets/opencode/opencode.base.json` — where plugin names get declared.
