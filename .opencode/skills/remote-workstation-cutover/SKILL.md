---
name: remote-workstation-cutover
description: Use when you need to drive this Mac remotely from cloudbox (hands-off darwin-rebuild / opencode cutover), or to understand/operate the security posture that keeps the public-IP cloudbox from reaching the Mac unattended. Covers opening the on-demand reverse-SSH window, the passwordless-root toggle, teardown, and revoking the cloudbox SSH key in JumpCloud.
---

# Remote Workstation Cutover (cloudbox → Mac)

The Mac can be driven remotely from `cloudbox` (a public-IP GCP sandbox) over a
reverse SSH tunnel: `ssh mac '<cmd>'` from cloudbox reaches this Mac's sshd via
`cloudbox 127.0.0.1:2222 -> Mac :22`, authenticating with cloudbox's
`~/.ssh/id_mac` (trusted in the Mac's JumpCloud-managed `authorized_keys`).

That capability is a lateral-movement path from a public box into a corporate
laptop, so it is **locked down by default** and opened only deliberately.

## Security posture (the two locked doors)

1. **The reverse tunnel is on-demand, not always-on.** `RemoteForward 2222`
   lives in a manual-only `Host cloudbox-cutover` (see
   `scripts/update-ssh-config.sh`), *not* in the always-on `cloudbox-tunnel`
   that the `cloudbox-dev-tunnel` LaunchAgent keeps up. Outside a window you
   open, `ssh mac` from cloudbox fails with `connect ... port 2222: Connection
   refused` — expected.
2. **No unattended root.** The `NOPASSWD: darwin-rebuild` sudoers rule is gated
   behind `enableUnattendedRemoteRoot` in `hosts/Y0FMQX93RR-2/configuration.nix`
   (default `false`). Even inside a cutover window, `sudo darwin-rebuild` needs a
   password unless you have flipped that toggle. Interactive/local
   `sudo darwin-rebuild` (Touch ID / password) is unaffected.

Net effect: a compromised cloudbox cannot reach the Mac unattended and cannot
get root. During a window you open, it can run commands **as your user** (not
root) — so keep windows short and don't open one if you suspect cloudbox is
compromised.

## Do a hands-off remote cutover (that needs root)

If the remote task only launches opencode / runs user-level commands, skip
steps 1–2 (no root toggle needed) and just open the window (step 3).

### 1. Enable unattended root (only if the remote task runs `sudo darwin-rebuild`)

Edit `hosts/Y0FMQX93RR-2/configuration.nix`:

```nix
enableUnattendedRemoteRoot = true;   # was false
```

### 2. Apply it locally (this rebuild is interactive; you're at the Mac)

```bash
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
```

### 3. Open the on-demand reverse-SSH window (from the Mac)

```bash
# Refresh the generated ssh config if cloudbox's IP may have changed:
bash ~/Code/workstation/scripts/update-ssh-config.sh

# Open the window in the background:
ssh -f -N -o ExitOnForwardFailure=yes cloudbox-cutover
```

Verify from cloudbox that it reaches back:

```bash
ssh cloudbox 'ssh -o BatchMode=yes mac "echo REACHED_MAC"'
# expect: REACHED_MAC
```

### 4. Do the remote work

Drive the cutover from cloudbox (`ssh mac '<cmd>'`, launch opencode, etc.).

### 5. Tear down — always revert when done

```bash
# Close the reverse-SSH window:
pkill -f 'ssh -f -N.*cloudbox-cutover'
ssh cloudbox 'ssh -o BatchMode=yes -o ConnectTimeout=5 mac true' \
  && echo "STILL OPEN (bad)" || echo "window closed (good)"
```

If you flipped the root toggle, set `enableUnattendedRemoteRoot = false;` again
and rebuild:

```bash
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
sudo -n /run/current-system/sw/bin/darwin-rebuild --help >/dev/null 2>&1 \
  && echo "STILL PASSWORDLESS (bad)" || echo "requires password (good)"
```

## Verifying the default (locked) posture

```bash
# No NOPASSWD darwin-rebuild rule:
sudo -n -l | grep -i darwin-rebuild || echo "no NOPASSWD (good)"

# 2222 is NOT always-on on cloudbox (2850 gclpr should still be present):
ssh -o ClearAllForwardings=yes cloudbox \
  'ss -tlnp 2>/dev/null | grep -E "127.0.0.1:(2222|2850)"'
# expect: only :2850
```

## Durably revoking cloudbox's SSH key (JumpCloud)

`~/.ssh/authorized_keys` is **constructed by the JumpCloud agent**, so editing
it locally does not stick and JumpCloud cannot push key options
(`from=`/`command=`/`restrict`). To durably remove or rotate the cloudbox key,
delete it at the source in JumpCloud. Identify it by name/fingerprint first:

```bash
grep 'cloudbox->mac' ~/.ssh/authorized_keys | ssh-keygen -lf -
# note the SHA256:... fingerprint and the key name
```

- **User Portal (self-service):** `https://console.jumpcloud.com/userconsole`
  → your profile → Security / SSH Keys → delete the `cloudbox->mac cutover
  driver` key.
- **Admin Console:** `https://console.jumpcloud.com` → USERS → your user →
  Details → SSH Keys → delete the key.

Then confirm the agent re-synced the Mac:

```bash
grep -c 'cloudbox->mac' ~/.ssh/authorized_keys   # want 0
# force a sync if it lingers (needs your sudo password now):
sudo launchctl kickstart -k system/com.jumpcloud.darwin-agent
```

Trade-off: deleting the key revokes remote cutovers entirely, even inside a
window. If you want to keep the workflow, leave the key in place — the on-demand
tunnel + no-unattended-root posture already contains the risk. Re-add a key in
JumpCloud if you ever need to restore access after deleting it.

## Scrubbing note

This is a public repo. Do NOT hardcode the GCP project name, cloudbox's public
IP (use `$CLOUDBOX_IP` / `gcloud`), any corporate email, or a JumpCloud org/SSO
URL here. See the `scrubbing-company-references` skill.
