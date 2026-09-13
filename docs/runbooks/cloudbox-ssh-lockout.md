# Runbook — locked out of cloudbox over SSH

**Audience: a human who cannot reach cloudbox right now.** Recovery is §1. Everything
explaining *why* is below it; skip until you are back in.

You are locked out of the box, so read this on GitHub or in a local clone — not on
cloudbox. Every command here runs from your laptop.

**Symptoms this runbook covers:** SSH to `34.24.187.96` **times out** rather than being
refused (GCP drops rather than rejects), launchd tunnels flap and reconnect forever, and it
works from home with WARP **off** but not with WARP **on**. The usual cause is that
Wonder's dedicated Zero Trust egress IP rotated or was deprovisioned, so your traffic no
longer matches `dev-ssh-warp`.

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

3. **Re-point the WARP rule at the new egress IP.** Once you are in by any route, find the
   address your WARP traffic now leaves from and update the rule:

   ```bash
   gcloud compute firewall-rules update dev-ssh-warp --source-ranges=<NEW_IP>/32
   ```

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
2026-09-13; re-read rather than trusting this table if it matters:

```bash
gcloud compute firewall-rules list --project=wonder-sandbox \
  --format='table(name,disabled,priority,sourceRanges.list(),targetTags.list(),
                  allowed[].map().firewall_rule().list(),logConfig.enable)'
```

| Rule | Allow | Source | Target tag | Pri | Logs |
|---|---|---|---|---|---|
| `dev-ssh-client` | `tcp:22`, `udp:60000-61000` | `147.185.152.0/21` (home ISP, Honest Networks) | `dev-ssh` | 900 | on |
| `dev-ssh-warp` | `tcp:22`, `udp:60000-61000` | `104.30.135.170/32` (Wonder ZT **dedicated** egress) | `dev-ssh` | 900 | on |
| `dev-ssh-iap` | `tcp:22` | `35.235.240.0/20` | `dev-ssh` | 900 | on |
| `allow-iap-ssh` | `tcp:22` | `35.235.240.0/20` | **none** | 900 | on |
| `allow-mosh` | `udp:60000-61000` | `0.0.0.0/0` | **none** | 1000 | off |
| `default-allow-ssh` | `tcp:22` | `0.0.0.0/0` | none | 65534 | **DISABLED** |

Two of these are load-bearing in non-obvious ways:

- **`allow-iap-ssh` is untagged and network-wide on purpose.** It duplicates `dev-ssh-iap`
  so that IAP break-glass still works if the instance loses its `dev-ssh` tag. Do not
  "deduplicate" it.
- **`default-allow-ssh` is disabled, not deleted.** That is what makes step 1.4 a one-liner.
  Delete it only after about a week of stable operation.

The `104.30.135.170` dedicated IP is only active on the **'Blue Apron'** WARP virtual
network. That vnet is described as legacy, so it may be retired someday — and a Cloudflare
org can hold a secondary dedicated IP in another city that traffic fails over to, which
would look exactly like the lockout symptoms above.

Instance: `cloudbox`, zone `us-east1-b`, tag `dev-ssh`, external IP `34.24.187.96`.

---

## 4. Known gap — which vnets work

| From | Direct SSH / scp / tunnels | Mosh |
|---|---|---|
| Home, WARP off | works | works |
| WARP 'Blue Apron' vnet | works | works |
| WARP Azure DEV/QA, Azure PROD, Default | **no — use IAP** | existing sessions keep working |

Those three vnets share a rotating pool IP that cannot be allowlisted. Existing mosh
sessions survive a vnet switch, but starting a **new** one from them needs its SSH
bootstrap to go over the IAP tunnel in §1.2.

---

## 5. Open action (human)

Ask whoever administers **wondergroup** Zero Trust for the full list of the org's dedicated
egress IPs — Zero Trust dashboard → **Address space → Leased IPs** — and add all of them to
`dev-ssh-warp`. Today the rule holds a single `/32`, so a colo failover to a secondary
dedicated IP causes a silent lockout with no signal other than the timeout in the header.
