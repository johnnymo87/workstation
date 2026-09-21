# Runbook — locked out of cloudbox over SSH

**Audience: a human who cannot reach cloudbox right now.** Recovery is §1. Everything
explaining *why* is below it; skip until you are back in.

You are locked out of the box, so read this on GitHub or in a local clone — not on
cloudbox. Every command here runs from your laptop.

**Symptoms this runbook covers:** SSH to `34.24.187.96` **times out** rather than being
refused (GCP drops rather than rejects), launchd tunnels flap and reconnect forever, and it
works from home with WARP **off** but not with WARP **on**.

> **IAP is the transport. There is no WARP allowlist rule and there will not be one.**
> `dev-ssh-warp` pinned a Cloudflare WARP egress `/32` that **rotates** — on 2026-09-15 it
> went `104.30.135.170 → 104.28.172.151` and took every forward down at once, while ICMP
> kept working and made the diagnosis misleading. The rule was deleted 2026-09-17 as the
> final step of the IAP cutover (`docs/plans/2026-09-17-iap-tunnel-cutover.md`, PR #545).
> IAP's source range `35.235.240.0/20` never rotates.
>
> So: **direct SSH from a WARP vnet timing out is the designed behaviour, not a lockout.**
> Do not recreate the rule to "fix" it — that reintroduces the exact fragility the cutover
> removed. Go to §1.2.

---

## 1. Get back in

In order. Stop at the first one that works.

1. **Turn WARP off**, connect from home. Home ISP is allowlisted directly
   (`dev-ssh-client`), so this bypasses the WARP egress IP entirely.

2. **IAP tunnel** — works from any network, including every WARP vnet:

   ```bash
   gcloud compute start-iap-tunnel cloudbox 22 \
     --local-host-port=localhost:2222 \
     --zone us-east1-b --project wonder-sandbox
   ssh -p 2222 dev@localhost
   ```

3. **If IAP itself is what broke**, the firewall is not your problem — check these in order,
   because the failure is almost certainly auth, not network:

   - **Has the tunnel service-account key expired?** It is USER_PROVIDED with a 90-day life
     and **expires 2026-12-16T22:32:47Z**. This is the single most likely future cause of a
     total lockout, because IAP is now the only routine path in.

     ```bash
     CLOUDSDK_CONFIG=~/.config/gcloud-tunnel/config \
       gcloud iam service-accounts keys list --managed-by=user \
       --iam-account=cloudbox-iap-tunnel@wonder-sandbox.iam.gserviceaccount.com
     ```

   - **Is the isolated config intact?** The SA lives in `~/.config/gcloud-tunnel/config`
     (0700), deliberately separate from your human gcloud account:

     ```bash
     CLOUDSDK_CONFIG=~/.config/gcloud-tunnel/config gcloud auth list
     ```

   - **Did you just change an IAM binding?** Propagation takes ~60–90s and a fresh binding
     returns `4033 'not authorized'` until it lands. Wait before chasing a second cause.

   Fall back to §1.1 (WARP off, from home) while you fix it — that path does not touch IAP.

4. **Full rollback**, if you need the door open now and cannot diagnose:

   ```bash
   gcloud compute firewall-rules update default-allow-ssh --no-disabled
   ```

   This re-enables SSH from `0.0.0.0/0`. It works from **any** network, because the GCP
   control plane is unaffected by a data-plane lockout — you do not need to be able to
   reach the box to run it. Re-disable it once the real rule is fixed.

---

## 2. Do not narrow `allow-mosh`

`allow-mosh` permits `udp:60000-61000` from `0.0.0.0/0`, and that is **deliberate**. It
looks like an oversight during any security review. It is not.

Wonder's dedicated Zero Trust egress IP applies to **TCP only**. Mosh's UDP egresses from
Cloudflare's *shared* WARP pool instead — measured at `104.28.165.70` on 2026-09-13, an
address that is neither stable nor allowlistable. Narrowing this rule breaks mosh roaming
across WARP toggles, which is a hard requirement.

It is also not costing us anything. SCC External Exposure scans a fixed **TCP** baseline
(22/23/3389, web ports, DB ports, k8s, dev tools) and **no UDP at all**, which is why this
rule sat at `0.0.0.0/0` for weeks without ever producing a finding.

---

## 3. The rules

GCP project `wonder-sandbox`, network `default`. Verified against the live project
2026-09-20; re-read rather than trusting this table if it matters:

```bash
gcloud compute firewall-rules list --project=wonder-sandbox \
  --format='table(name,disabled,priority,sourceRanges.list(),targetTags.list(),
                  allowed[].map().firewall_rule().list(),logConfig.enable)'
```

| Rule | Allow | Source | Target tag | Pri | Logs |
|---|---|---|---|---|---|
| `dev-ssh-client` | `tcp:22`, `udp:60000-61000` | `147.185.152.0/21` (home ISP, Honest Networks) | `dev-ssh` | 900 | on |
| `dev-ssh-iap` | `tcp:22` | `35.235.240.0/20` | `dev-ssh` | 900 | on |
| `allow-iap-ssh` | `tcp:22` | `35.235.240.0/20` | **none** | 900 | on |
| `allow-mosh` | `udp:60000-61000` | `0.0.0.0/0` | **none** | 1000 | off |
| `default-allow-ssh` | `tcp:22` | `0.0.0.0/0` | none | 65534 | **DISABLED** |

There was a sixth rule, `dev-ssh-warp`, pinned to a Cloudflare WARP dedicated egress `/32`.
It was deleted 2026-09-17 by the IAP cutover and **is not coming back** — see the note at
the top.

Three of these are load-bearing in non-obvious ways:

- **`allow-iap-ssh` is untagged and network-wide on purpose.** It duplicates `dev-ssh-iap`
  so that IAP break-glass still works if the instance loses its `dev-ssh` tag. Do not
  "deduplicate" it.
- **`dev-ssh-client` is the only non-IAP way in.** Now that the WARP rule is gone, this
  home-ISP range is what `cloudbox-tunnel-direct` and §1.1 rely on when IAP is down. It
  looks like a leftover of the old pinned-IP scheme. It is not — keep it.
- **`default-allow-ssh` is disabled, not deleted.** That is what makes step 1.4 a one-liner.
  Delete it only after about a week of stable operation.

Instance: `cloudbox`, zone `us-east1-b`, tag `dev-ssh`, external IP `34.24.187.96`.

---

## 4. Which network you are on no longer matters

Since the cutover, every routine path goes through IAP, so the old per-vnet table is moot —
the answer is the same from everywhere:

| From | SSH / scp / tunnels | Mosh |
|---|---|---|
| Any network, WARP on or off | via IAP ProxyCommand (`~/.ssh/config`) | works |
| Home ISP, WARP off | also works direct (`dev-ssh-client`) — the IAP-outage fallback | works |

**Direct SSH to `34.24.187.96` from a WARP vnet does not work and is not meant to.** No
WARP egress, dedicated or pooled, is allowlisted.

Mosh is the one place a raw path still exists, and it is fine: the bootstrap is TCP:22
through the IAP ProxyCommand like everything else, while the UDP data packets go direct to
the instance IP under `allow-mosh` — which is why §2 says not to narrow that rule.

---

## 5. Open actions (human)

1. **Rotate the IAP tunnel service-account key before 2026-12-16T22:32:47Z.** IAP is now the
   only routine way in, so an expired key is a full lockout with §1.1 (home ISP, WARP off)
   as the sole fallback. Note the rotation touches **two** cleartext copies of the private
   key inside `~/.config/gcloud-tunnel/config` — `credentials.db` and
   `legacy_credentials/<sa>/adc.json` — not one; see
   `docs/plans/2026-09-17-iap-tunnel-cutover.md`.

2. **Decide whether to delete `default-allow-ssh`.** It has been disabled, not deleted,
   since 2026-09-13 specifically so §1.4 stays a one-liner. Week-long firewall logs to
   2026-09-20 show SSH arriving only over IAP (48 hits) and from the home ISP range (2
   hits). Deleting it removes the break-glass in §1.4, so it is a real trade, not cleanup.
