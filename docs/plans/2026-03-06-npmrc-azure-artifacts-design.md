# Declarative .npmrc for Azure DevOps Artifacts

Generate `~/.npmrc` with home-manager on work machines, using npm's native env var
interpolation to inject the Azure DevOps PAT at runtime.

## Context

Internal npm packages live in Azure Artifacts at
`pkgs.dev.azure.com/foodtruckinc/Wonder/_packaging/npm-local/`. Authentication
requires a PAT (Personal Access Token) base64-encoded in the `_password` field of
`~/.npmrc`.

Currently the `.npmrc` is manually maintained with the base64-encoded PAT inline.
The raw PAT is already stored in sops (cloudbox) and macOS Keychain, exported as
`SYSTEM_ACCESSTOKEN`.

## Approach Chosen

**Env var interpolation** -- npm natively supports `${ENV_VAR}` in `.npmrc`. The
literal `${ADO_NPM_PAT_B64}` stays in the file; npm resolves it from the process
environment at invocation time.

### Alternatives Considered

| Approach | Why not |
|----------|---------|
| sops-nix templates | NixOS-only (no macOS), renders to `/run/secrets-rendered/` |
| home.activation script | Mutable file, only runs on rebuild, more complex |
| ado-npm-auth / azdo-npm-auth | Interactive login required, immature tooling, heavy deps |
| Azure CLI token exchange | Short-lived tokens (~1h), needs refresh wrapper |
| Managed identity / service principal | Overkill for dev, cloudbox is GCP not Azure |

### Key Technical Details

- npm `${ENV_VAR}` is resolved at **read-time** from the process environment, not
  file substitution. The literal string stays in the file.
- Azure DevOps requires `_password` (base64 of PAT), not `_authToken` (raw token).
  Microsoft docs do not support raw PAT in `_authToken` for Azure Artifacts.
- Both `/registry/` and non-`/registry/` auth entries are needed (Microsoft docs
  include both; omitting one can cause partial 401 failures).
- The Nix store copy of `.npmrc` contains no secrets -- only `${ADO_NPM_PAT_B64}`
  references -- so 0644 permissions are fine.

## Design

### File: `users/dev/home.base.nix`

Add `home.file.".npmrc"` guarded by `lib.mkIf (isDarwin || isCloudbox)`:

```nix
home.file.".npmrc" = lib.mkIf (isDarwin || isCloudbox) {
  text = ''
    ; begin auth token
    //pkgs.dev.azure.com/foodtruckinc/Wonder/_packaging/npm-local/npm/registry/:username=foodtruckinc
    //pkgs.dev.azure.com/foodtruckinc/Wonder/_packaging/npm-local/npm/registry/:_password=''${ADO_NPM_PAT_B64}
    //pkgs.dev.azure.com/foodtruckinc/Wonder/_packaging/npm-local/npm/registry/:email=npm requires email to be set but doesn't use the value
    //pkgs.dev.azure.com/foodtruckinc/Wonder/_packaging/npm-local/npm/:username=foodtruckinc
    //pkgs.dev.azure.com/foodtruckinc/Wonder/_packaging/npm-local/npm/:_password=''${ADO_NPM_PAT_B64}
    //pkgs.dev.azure.com/foodtruckinc/Wonder/_packaging/npm-local/npm/:email=npm requires email to be set but doesn't use the value
    ; end auth token
  '';
};
```

Note: `''${...}` is Nix's escape for literal `${...}` in multiline strings.

### File: `users/dev/home.cloudbox.nix`

Add one line after the existing `SYSTEM_ACCESSTOKEN` export:

```bash
# After: export SYSTEM_ACCESSTOKEN="$(cat /run/secrets/azure_devops_pat)"
export ADO_NPM_PAT_B64="$(printf '%s' "$SYSTEM_ACCESSTOKEN" | base64 -w0)"
```

### File: `users/dev/home.darwin.nix`

Add one line after the existing `SYSTEM_ACCESSTOKEN` export:

```bash
# After: AZDO_VAL="$(...)" && export SYSTEM_ACCESSTOKEN="$AZDO_VAL"
export ADO_NPM_PAT_B64="$(printf '%s' "$SYSTEM_ACCESSTOKEN" | base64)"
```

macOS `base64` does not wrap output by default, so `-w0` is unnecessary.

## PAT Rotation

When the PAT expires:

1. Mint new PAT at `dev.azure.com/foodtruckinc/_usersSettings/tokens`
2. Update sops (`azure_devops_pat`) and/or Keychain (`azure-devops-pat`)
3. Start a new shell -- env var re-reads the secret automatically

No home-manager rebuild needed for rotation.

## Security

- PAT never enters the Nix store
- Base64 encoding happens in-memory at shell init
- `.npmrc` file contains only env var references
- Existing `SYSTEM_ACCESSTOKEN` infrastructure is reused, no new secrets

## Scope

npm only. pip and maven artifact registry auth can follow the same pattern later.
