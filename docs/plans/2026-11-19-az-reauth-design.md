# az-reauth: keep the Azure CLI login alive on the Mac and the remote

Status: design approved 2026-11-19. Bead: `workstation-idqg`. The implementation
plan is written after the token-lifetime measurement below comes back.

## Problem

A Conditional Access sign-in-frequency policy caps every Azure CLI login at
24 hours. Refreshing does not extend it; az fails with

    AADSTS70043: The refresh token has expired or is invalid due to sign-in
    frequency checks by conditional access ... maximum allowed lifetime for
    this request is 86400.

Agents on the remote hit this in 15+ sessions since mid-October and the human
re-runs `az login` there about once a day. The Mac's own az login has been dead
since September.

## Measured facts this design rests on

- Both hosts keep az's tokens in a plaintext `~/.azure/msal_token_cache.json`
  (mode 0600). The Mac does not encrypt it into the Keychain, so the file can be
  copied between hosts.
- Each host's `azureProfile.json` differs (the default subscription is different
  on each), so only the token cache may be copied.
- The isolated Chrome used by gcloud-reauth (CDP on `127.0.0.1:9223`) holds a
  live Entra session. Its history shows a real password sign-in about every
  18-19 h, at the same moments the gcloud flow needed a human IdP sign-in.
- A spike on 2026-11-19 completed `az login` silently in that Chrome: the
  "Pick an account" page, one click on the account tile, the redirect to az's
  loopback listener, az exit 0. No password, no MFA. The access token carried
  `amr: [pwd, mfa]`.
- **Open:** whether a refresh token from a silent login lives 24 h from its
  issue, or only until 24 h after the session's last real sign-in. Measured on
  2026-11-20 against the spike cache in `~/.local/state/az-reauth-spike/cfg`.
  It decides how much trigger (b) below matters, not whether the design works.

## Design

A new credential, `az`, inside the existing hourly job
(`assets/gcloud-reauth/refresh.sh`), alongside `cli`, `adc` and `mac-adc`.

### Login (on the Mac)

`az login --tenant "$AZ_TENANT"` runs with a throwaway `AZURE_CONFIG_DIR` and a
`BROWSER` stub that records the authorize URL and exits. A new harness script,
`az-login.mjs`, opens that URL in a background tab of the isolated Chrome
(`bg-page.mjs`) and clicks the account tile. If Entra shows anything else
(password, MFA, consent), it types nothing, records `idp_login_required` and
raises the same sign-in alert as gcloud. The login is accepted only when az
exits 0 **and** `az account get-access-token` succeeds against the throwaway
directory.

The loopback flow means the browser and the az process must be on the same
host, which is why the login runs on the Mac and the result is copied.

### When it runs

When any of these holds:

- (a) 6 h have passed since the last successful az login (gcloud's cadence);
- (b) this run needed a human IdP sign-in, since that is the moment the Entra
  session is fresh;
- (c) the Mac's or the remote's `az account get-access-token` fails;
- (d) `--force`.

### Installing

Only `msal_token_cache.json` is copied.

- Mac: written to `~/.azure/` with mode 0600 and an atomic rename.
- Remote: copied over ssh to a temporary file beside the target, then renamed
  into place while holding az's own MSAL lock file
  (`msal_token_cache.json.lockfile`), so a concurrent az process cannot write the
  old cache back.
- Each host is then checked with `az account get-access-token`.

The jsonl rows are `az` (the login) and `az-sync` (the installs), each with its
own alert slot. An az failure never affects the gcloud credentials or their exit
status. A login that fails verification installs nothing, and a failed install
is retried on the next hourly run.

### Wiring

`users/dev/home.darwin.nix`: `azure-cli` in the job's `runtimeInputs`, and the
tenant id read from a Keychain entry (`az-tenant`) so it stays out of public
source.

### Testing

- Fixture cases for the decision logic (a)-(d) and both install paths.
- `shellcheck -S warning`.
- One real run against both hosts before the PR.

## Consequences

- The two hosts share one Azure refresh token, so `az logout` on either kills
  both.
- Entra's sign-in log shows an Azure CLI interactive sign-in about every 6 h.
- The first run replaces the remote's hand-made login.
- az stays alive only while the Chrome's Entra session is less than 24 h old.
  That holds while the human keeps answering the gcloud sign-in prompts. A day
  without one lapses az too, and that prompt is the cue.
- If per-session `AZURE_CONFIG_DIR` (`workstation-ph89`) ever lands, the install
  target must remain the shared cache.

## Rejected

- **Remote runs `az login` and the Mac's Chrome completes it through an ssh
  tunnel to the loopback port.** No credential crosses hosts, but it adds a
  tunnel and a remote-initiated browser step to every login. The human has
  accepted copying credentials (as for the Mac ADC), so the extra parts buy
  nothing.
- **Device-code login on the remote with the Chrome entering the code.** It is
  the most fragile option, and device-code flow is a common Conditional Access
  block.
