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

The `installOpencodePlugins` activation already automates this. If you bypass
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

In `users/dev/opencode-config.nix`, the activation:

1. Reads the `opencodePluginPins` attrset (currently just
   `@ex-machina/opencode-anthropic-auth`).
2. Runs `npm install <pkg>@<pin> --no-save` (legacy/parallel copy — see
   note above; we keep it as a side-effect documentation of intent).
3. **For each pin, checks the cached version and `rm -rf`s the cache dir
   if it doesn't match.**
4. **If anything was invalidated, restarts opencode-serve via sudo** (devbox
   and cloudbox only — both have `wheelNeedsPassword=false`).

Result: bumping the version pin and running `home-manager switch` Just
Works™. You'll see log lines like:

```
installOpencodePlugins: @ex-machina/opencode-anthropic-auth cached at 1.2.0, pinned at 1.8.0 -> purging /home/dev/.cache/opencode/packages/@ex-machina/opencode-anthropic-auth@latest
installOpencodePlugins: restarted opencode-serve after cache invalidation
```

When pin == cache, no purge, no restart, no log lines (idempotent).

## Adding a New Pinned Plugin

1. Add the entry to `opencode.base.json`'s `plugin: [...]` array.
2. Add the version pin to `opencodePluginPins` in
   `users/dev/opencode-config.nix:installOpencodePlugins`:

   ```nix
   opencodePluginPins = {
     "@ex-machina/opencode-anthropic-auth" = "1.8.0";
     "your-new-plugin" = "0.3.1";  # add this
   };
   ```

3. Run `nix run home-manager -- switch --flake .#$(cat /etc/hostname)`.
4. Verify with the `find ... package.json` recipe above.

## Bumping an Existing Pin

1. Check what's on npm: `npm view <plugin-name> versions --json | jq '.[-5:]'`
2. Edit the version in `opencodePluginPins`.
3. `nix run home-manager -- switch --flake .#$(cat /etc/hostname)`.
4. Watch for `installOpencodePlugins:` log lines confirming purge + restart.
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
SID=$(curl -s -X POST http://127.0.0.1:4096/session | jq -r '.id')
curl -s -X POST "http://127.0.0.1:4096/session/$SID/message" \
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
