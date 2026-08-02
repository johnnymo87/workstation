# Vendored upstream loader sources

Verbatim copies of the two opencode files that `plugin-loader-contract.test.ts`
replicates, at the version in `LOADER_VERSION`:

- `plugin-index.ts` — `packages/opencode/src/plugin/index.ts`
  (`getLegacyPlugins` throw at :103, `applyPlugin` v1 early-return at :115)
- `plugin-shared.ts` — `packages/opencode/src/plugin/shared.ts`
  (`readV1Plugin`, `readPluginId`, `resolvePluginId` file-source `id` throw at :315)

They exist so that re-verifying the replica after an opencode bump is a
mechanical diff rather than a re-reading exercise. The pin test fails when
`upstreamVersion` in `users/dev/home.base.nix` moves ahead of `LOADER_VERSION`;
its failure message contains the exact `curl | diff` commands.

Do not edit by hand. Refresh with:

    V=<new-version>
    for f in index shared; do
      curl -sL "https://raw.githubusercontent.com/sst/opencode/v$V/packages/opencode/src/plugin/$f.ts" \
        -o "assets/opencode/plugins/test/fixtures/plugin-$f.ts"
    done

These are reference material, not compiled or imported by the test suite.
