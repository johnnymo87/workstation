# Cut the Mac→cloudbox SSH transport over to IAP (service-account auth)

**Status:** GCP side DONE and verified. Mac side NOT STARTED.
**Worktree:** `~/Code/workstation/.worktrees/iap-tunnel` (branch off origin/main).

## Why

The Mac→cloudbox reverse SSH tunnel carries gclpr clipboard (2850), Chrome CDP
(9222/9223), chatgpt-relay (3033) and the Jenkins proxy (8443). Reachability was
gated by a GCP firewall rule `dev-ssh-warp` pinned to the Mac's Cloudflare WARP
egress `/32`. That egress **rotates** (it rotated 2026-09-15:
`104.30.135.170 → 104.28.172.151`) and took every forward down at once. ICMP kept
working (`default-allow-icmp` is `0.0.0.0/0`), which made diagnosis misleading.

Goal: make the transport independent of source IP. IAP's source range
(`35.235.240.0/20`) never changes. IAP with the *user's* credentials is
self-defeating because those are subject to the daily Google session-control
reauth this whole project exists to automate — hence a **service account**, which
is not subject to it.

## Completed (GCP) — all verified

| Thing | Value |
|---|---|
| SA | `cloudbox-iap-tunnel@wonder-sandbox.iam.gserviceaccount.com` |
| Custom role | `projects/wonder-sandbox/roles/iapTunnelInstanceReader` = `{compute.instances.get}` ONLY |
| Custom role binding | on the **instance** `cloudbox` (us-east1-b) |
| IAP binding | `roles/iap.tunnelResourceAccessor` on IAP tunnel resource, condition `destination.port == 22` (title `ssh-only`) |
| Key | USER_PROVIDED X.509, key id `7642eaee63905e6404dfc67be44a19982d2eb679`, **expires 2026-12-16T22:32:47Z** (90d) |
| Isolated gcloud config | `~/.config/gcloud-tunnel/config` (0700), SA activated into it |

Notes learned the hard way:
- `gcloud compute instances add-iam-policy-binding` **cannot** bind
  `roles/iap.tunnelResourceAccessor` ("not supported for this resource"), and this
  gcloud has no `iap tcp add-iam-policy-binding`. Use the REST API:
  `POST https://iap.googleapis.com/v1/projects/38001078732/iap_tunnel/zones/us-east1-b/instances/cloudbox:setIamPolicy`
  with policy `version: 3`.
- **IAM propagation takes ~60–90s.** First positive test returned `4033` purely
  because of propagation; do not chase a second root cause before waiting.
  (GCP *firewall* changes also took ~2 min earlier the same day.)
- `compute.instances.get` alone is sufficient because `--zone` is always passed.
  Project-level `compute.instances.list` was NOT needed and would have exposed
  metadata/startup scripts for every VM in the project.
- Duplicate key material (`sa-credentials.json`, `sa-private.pem`, `sa-cert.pem`)
  was deleted after activation. The only copy now lives in the isolated
  `credentials.db`. At-rest protection is FileVault.

### Acceptance tests already passing
- positive: `CLOUDSDK_CONFIG=~/.config/gcloud-tunnel/config gcloud compute start-iap-tunnel cloudbox 22 --local-host-port=localhost:2224 --zone=us-east1-b --project=wonder-sandbox` → ssh through it returns `SA-TUNNEL-OK` / `cloudbox`
- negative: same but port `4710` → `4033: 'not authorized'` (proves the IAM condition binds, not merely the role)
- isolation: `env -u CLOUDSDK_CONFIG gcloud auth list` still shows `jmohrbacher@wonder.com` active
- key expiry: `gcloud iam service-accounts keys list --managed-by=user` shows `EXPIRES_AT 2026-12-16`

## Remaining work (Mac)

Files:
- `scripts/update-ssh-config.sh` — generates the ssh host blocks (`cloudbox`,
  `cloudbox-tunnel`, `cloudbox-chart`, `cloudbox-cutover`). Line ~80 and ~146
  carry `RemoteForward 2850`.
- `users/dev/home.darwin.nix` — `sshTunnelCommand` helper (line 9) and the
  `cloudbox-dev-tunnel` LaunchAgent (line ~201).

1. **ssh block keyed `Host cloudbox 34.24.187.96`** (MUST include the IP literal —
   see mosh note below), with:
   - `ProxyCommand env CLOUDSDK_CONFIG=%d/.config/gcloud-tunnel/config ${pkgs.google-cloud-sdk}/bin/gcloud compute start-iap-tunnel cloudbox 22 --listen-on-stdin --zone=us-east1-b --project=wonder-sandbox`
     (absolute path: launchd PATH is minimal)
   - `HostKeyAlias 34.24.187.96` — `known_hosts` stores the key under the IP, not
     the name. Without this, host key verification fails.
   - do NOT set `BatchMode yes` (that was a test artifact).
2. **Keep a `cloudbox-tunnel-direct` variant** (no ProxyCommand) and have the
   retry loop alternate IAP → direct, so a Google-side IAP outage is non-fatal.
3. **mosh wrapper** (home-manager). mosh 1.4.0 defaults to
   `--experimental-remote-ip=proxy`, which injects its own `--fake-proxy`
   ProxyCommand on the ssh **command line** and thereby overrides ssh_config —
   silently reverting to the fragile direct path. Must always pass
   `--experimental-remote-ip=local`. In `local` mode mosh **rewrites the host to
   the literal IP** before exec'ing ssh, which is why the ssh block must match the
   IP, not the name. Wrapper derives the IP from ssh_config so there is no
   hardcoded IP and no `/etc/hosts` entry:
   ```sh
   host=${1:?}; shift
   ip=$(ssh -G "$host" | awk '$1=="hostname"{print $2}')
   user=$(ssh -G "$host" | awk '$1=="user"{print $2}')
   exec mosh --experimental-remote-ip=local \
     --server='MOSH_SERVER_NETWORK_TMOUT=604800 mosh-server' \
     "$user@$ip" "$@"
   ```
   `MOSH_SERVER_NETWORK_TMOUT` stops detached mosh-servers accumulating (each
   holds a pty + UDP listener). No sudo needed — **cloudbox's sudo is currently
   broken** (`must be owned by uid 0 and have the setuid bit set`).
4. **LaunchAgent hardening** in `sshTunnelCommand`: capped backoff 10s→60s, and a
   **three-way** failure classification — network (`curl -sI https://oauth2.googleapis.com`)
   → auth (`gcloud auth print-access-token`) → transport (ssh/IAP). After 3
   consecutive failures, `osascript -e 'display notification'` + a marker file
   recording which path (iap/direct) is up. Today's outage was invisible until a
   human noticed a broken clipboard.
5. **Verify end-to-end**: tunnel reconnects; from cloudbox
   `curl http://127.0.0.1:9223/json/version` returns browser UUID
   `1ed522e8-3fed-416b-bb61-cea1b27a19b3` (the isolated Chrome-gcloud instance —
   NOT `a1611d6c-…`, which is the unrelated 9222 dev Chrome); clipboard round-trip
   via `gclpr copy`; `mosh cloudbox` works.
6. **Delete `dev-ssh-warp` after cutover** (a stale shared-Cloudflare `/32` hands
   random tenants a path to sshd). **KEEP `dev-ssh-client`** — that is
   `147.185.152.0/21`, the *home ISP* range (Honest Networks), the WARP-off
   fallback. It is NOT Twingate; it was nearly deleted on that wrong guess.
7. **Schedule a T-7d key rotation wake** (before 2026-12-16). Rotation runbook is
   overlap-then-delete: upload new key → switch → verify tunnel → delete old.
   Never delete-then-create.

## Mosh facts (established by source read + empirical test)

- mosh has two independent channels. SSH bootstrap (TCP/22) honors ProxyCommand →
  rides IAP. UDP data (60000-61000) goes direct to the instance IP, and
  `allow-mosh` is already `0.0.0.0/0` → never was source-IP-bound.
- Proven: `SSH_CONNECTION=35.235.243.209 …` (inside `35.235.240.0/20`) while the
  session ran, i.e. bootstrap over IAP, data over UDP.
- Live mosh sessions survive IAP outage and SA key expiry; only new bootstraps
  fail. This is strictly better than the SSH-only tunnel.
- `allow-mosh 0.0.0.0/0` is now deliberate, load-bearing infrastructure. Judged
  acceptable (mosh-server silently drops packets failing AES-OCB auth; the port
  only exists while a server lives) and cannot be tightened without
  reintroducing source-IP dependence. Write this decision down.

## Constraints (user-imposed, non-negotiable)

- Never bind a debugging port to `0.0.0.0`; never `ssh -g`; never GatewayPorts.
- Never type/store/automate a password or MFA code.
- Do not disturb the everyday Chrome or the 9222 instance.
- Do not sign the personal Google account into the isolated Chrome.
- Repo rule: work in the worktree, never commit at the primary root. Commit bare
  (no `-c user.email=`).

## Review status

`adversarial-reviewer-fable` gave full buy-in on the second pass. Its five
original blocking objections are all discharged in the design above.
