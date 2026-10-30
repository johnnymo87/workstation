---
name: remote-workstation-cutover
description: Use when you need to drive this Mac remotely from cloudbox — most often to repair the Mac's opencode/Claude access after an upgrade broke it (home-switch, no root), occasionally a hands-off system repair (darwin-rebuild via the passwordless-root toggle) — or to understand/operate the security posture that keeps the public-IP cloudbox from reaching the Mac unattended. Covers opening the on-demand reverse-SSH window, home-level vs system-level repair, the passwordless-root toggle, teardown, and revoking the cloudbox SSH key in JumpCloud.
---

# Remote Workstation Cutover (cloudbox → Mac)

The Mac can be driven remotely from `cloudbox` (a public-IP GCP sandbox) over a
reverse SSH tunnel: `ssh mac '<cmd>'` from cloudbox reaches this Mac's sshd via
`cloudbox 127.0.0.1:2222 -> Mac :22`, authenticating with cloudbox's
`~/.ssh/id_mac` (trusted in the Mac's JumpCloud-managed `authorized_keys`).

The usual reason: an upgrade broke the Mac's own Claude/opencode, so the Mac
cannot fix itself, and a Claude on cloudbox does it instead.

## First decide: home-level or system-level repair?

**Most repairs need no root at all.** Home-manager on the Mac is standalone
(`homeConfigurations.Y0FMQX93RR-2`, deployed by `home-switch`), so everything
that usually breaks Claude access is user config:

| Broken thing | Where it lives | Fix | Root? |
|---|---|---|---|
| opencode config, providers, MCP servers | `users/dev/opencode-config.nix` | `home-switch` | **No** |
| opencode plugins, skills, agents | `assets/opencode/`, `users/dev/opencode-skills.nix` | `home-switch` | **No** |
| opencode serve / frontdoor / cfp / tunnels (launchd agents) | `users/dev/home.darwin.nix` | `home-switch`, or `launchctl kickstart -k gui/$(id -u)/org.nix-community.home.<name>` | **No** |
| the opencode binary itself | `users/dev/home.base.nix` | `home-switch` | **No** |
| Remote Login (sshd) itself is off | macOS setting | System Settings / `systemsetup` at the Mac | **Yes** |
| nix.conf, nix-daemon, /etc/bashrc, /etc/shells, login shell, sudoers | `hosts/Y0FMQX93RR-2/` | `darwin-switch` | **Yes** |

A home-level repair is: open the window (step 2 below), then from cloudbox

```bash
ssh mac 'cd ~/Code/workstation && git pull --ff-only && ~/.nix-profile/bin/home-switch'
```

No toggle, no sudoers change, no Admin By Request window. Full paths matter:
an `ssh mac '<cmd>'` shell is non-interactive and may not have the profile on
`PATH`. If `home-switch` itself is broken, use
`nix run ~/Code/workstation#home-switch` (with
`/run/current-system/sw/bin` on `PATH` for `nix`).

**Caveats for home repair over SSH:**

- **The login Keychain is normally locked over SSH**, and home activation
  reads ~20 secrets from it. On a failed read, activation does not fail — it
  *removes* the MCP entries and the Claude proxy routing from opencode's
  config. `home-switch` therefore refuses to run when it cannot read the
  `google-cloud-project` item. Run `security unlock-keychain
  ~/Library/Keychains/login.keychain-db` in the SSH session first (prompts for
  the login password). The same unlock lets the cfp seed work.
- **launchd agents re-bootstrapped from an SSH session: unverified.**
  home-manager boots out a changed agent and `launchctl bootstrap gui/$UID`s
  the new plist, ignoring failures. Whether that bootstrap succeeds from a
  non-GUI SSH session has not been tested on this Mac. After a remote
  `home-switch`, check the agents you care about:
  `launchctl print gui/$(id -u)/org.nix-community.home.opencode-serve-0 | grep state`.
- **`home-switch` restarts the opencode serves if their plists changed** — fine
  when the point is to repair them, but do not drive it from an opencode
  session *on the Mac*.

Only a **system-level** repair needs the passwordless-root toggle below.

## Security posture (the two locked doors)

1. **The reverse tunnel is on-demand, not always-on.** `RemoteForward 2222`
   lives in a manual-only `Host cloudbox-cutover` (see
   `scripts/update-ssh-config.sh`), *not* in the always-on `cloudbox-tunnel`
   that the `cloudbox-dev-tunnel` LaunchAgent keeps up. Outside a window you
   open, `ssh mac` from cloudbox fails with `connect ... port 2222: Connection
   refused` — expected.
2. **No unattended root.** The `NOPASSWD: darwin-rebuild` sudoers rule is gated
   behind `enableUnattendedRemoteRoot` in `hosts/Y0FMQX93RR-2/configuration.nix`
   (default `false`). Without it, `sudo darwin-rebuild` over SSH needs a
   password — and once IT removes local admin, an ordinary password does not
   help either: interactive sudo works **only inside an Admin By Request
   window**, which the person at the Mac has to request.

Net effect: a compromised cloudbox cannot reach the Mac unattended. During a
window you open, it can run commands **as your user** — which, thanks to
standalone home-manager, is enough for most repairs. Keep windows short and
don't open one if you suspect cloudbox is compromised.

**"As your user" is not "no path to root" on this Mac**, toggle or not:

- You are in nix's `trusted-users` (`hosts/Y0FMQX93RR-2/configuration.nix`),
  which nix itself documents as essentially root-equivalent: a trusted user can
  import unsigned store paths, e.g. plant the output that the next elevated
  `darwin-switch` activates as root.
- `darwin-switch` deploys `~/Code/workstation`, which you own. Anything that ran
  as you can edit `hosts/` and have it applied as root at the next Admin By
  Request elevation.

Both are deferred (they need a later elevation or a later deploy to bite), but
they are real. The toggle is the only path that needs no later elevation.

### How the toggle behaves without local admin

- **Turning it on needs root once**: it is a system deploy, so `darwin-switch`
  inside an Admin By Request window.
- **Once installed, it keeps working with no admin and no window.** The rule
  is `<username> ALL=(root) NOPASSWD: /run/current-system/sw/bin/darwin-rebuild`
  — keyed on the username, not `%admin` — so admin removal does not touch it.
  That is exactly what makes it useful here, and exactly what makes it
  dangerous: it **bypasses Admin By Request**, whose job is to make root
  short-lived and audited. `darwin-rebuild` activates arbitrary system config,
  so this is root for anyone who can run commands as you.
- **Turning it off needs no window**: while the rule is installed,
  `darwin-switch`'s `sudo /run/current-system/sw/bin/darwin-rebuild` is the
  command it allows. Flip it back the same day.
- **IT's management may remove it.** JumpCloud already writes files into
  `/etc/sudoers.d`. If its policy ever prunes files it did not write, the rule
  silently disappears; that fails closed (`sudo -n` starts asking for a
  password), never open.

### SSH access after admin removal (what is verifiable)

**First, sshd has to be running at all.** As of 2026-10-30 Remote Login is
**disabled** on this Mac (`launchctl print-disabled system` shows
`"com.openssh.sshd" => disabled`; `nc -z 127.0.0.1 22` is refused), so the
cutover tunnel has nothing to reach. Enabling it is root-only
(`sudo systemsetup -setremotelogin on`, or System Settings → General →
Sharing), i.e. an Admin By Request window, and IT's MDM may own the setting.
The migration plan does it optionally in its elevated step. Check:

```bash
launchctl print-disabled system | grep sshd   # want: enabled, or no line
nc -z 127.0.0.1 22 && echo "sshd listening"
```

Given that, access is gated by macOS's SSH service ACL, not by admin:
`/etc/pam.d/sshd` has `account required pam_sacl.so sacl_service=ssh`, which
checks membership of `com.apple.access_ssh`. On this Mac the user is a
**direct** member of that group (`dscl . -read /Groups/com.apple.access_ssh
GroupMembership` lists the username; the group has no nested `admin` group), so
removing `admin` does not by itself remove SSH access. Checked 2026-10-30:

```bash
/usr/sbin/dseditgroup -o checkmember -m "$USER" com.apple.access_ssh   # yes ... is a member
dscl . -read /Groups/com.apple.access_ssh NestedGroups                 # No such key
```

What cannot be verified from here: whether IT's MDM will also change Remote
Login's allowed-users list or the JumpCloud-built `authorized_keys`. Re-run the
two commands above after admin is removed; if either changes, remote repair is
gone until IT restores it.

## Do a remote repair

### 1. System-level only: enable unattended root (at the Mac, elevated)

Skip for home-level repairs. Edit `hosts/Y0FMQX93RR-2/configuration.nix`:

```nix
enableUnattendedRemoteRoot = true;   # was false
```

Request an Admin By Request window, then:

```bash
darwin-switch
# After the window closes, prove the rule works without it:
sudo -k; sudo -n /run/current-system/sw/bin/darwin-rebuild --help >/dev/null 2>&1 \
  && echo "NOPASSWD installed" || echo "NOT installed"
```

`darwin-switch` seeds the cfp asset best-effort; the system build does not
need it, so a locked Keychain over SSH does not block a later remote
`darwin-switch`.

### 2. Open the on-demand reverse-SSH window (from the Mac)

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

### 3. Do the remote work

Drive the repair from cloudbox: `ssh mac '<cmd>'`, `home-switch` (see the
table above), or — with the toggle on — `darwin-switch` /
`sudo /run/current-system/sw/bin/darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2`.

### 4. Tear down — always revert when done

```bash
# Close the reverse-SSH window:
pkill -f 'ssh -f -N.*cloudbox-cutover'
ssh cloudbox 'ssh -o BatchMode=yes -o ConnectTimeout=5 mac true' \
  && echo "STILL OPEN (bad)" || echo "window closed (good)"
```

If you flipped the root toggle, set `enableUnattendedRemoteRoot = false;` again
and rebuild. No window needed — the rule being removed is what authorizes it:

```bash
darwin-switch
sudo -k; sudo -n /run/current-system/sw/bin/darwin-rebuild --help >/dev/null 2>&1 \
  && echo "STILL PASSWORDLESS (bad)" || echo "requires password (good)"
```

## Verifying the default (locked) posture

```bash
# No NOPASSWD darwin-rebuild rule. Needs no elevation: with no NOPASSWD rule,
# `sudo -n` fails ("a password is required"), which is the good outcome.
sudo -k; sudo -n /run/current-system/sw/bin/darwin-rebuild --help >/dev/null 2>&1 \
  && echo "NOPASSWD present (bad unless mid-repair)" || echo "no NOPASSWD (good)"

# Is the rule file even there? (readable without root: /etc/static is a symlink farm)
ls -la /etc/sudoers.d/darwin-rebuild 2>/dev/null || echo "no rule file (good)"

# 2222 is NOT always-on on cloudbox (2850 gclpr should still be present):
ssh -o ClearAllForwardings=yes cloudbox \
  'ss -tlnp 2>/dev/null | grep -E "127.0.0.1:(2222|2850)"'
# expect: only :2850
```

`sudo -n -l` (listing your sudo rights) is no longer a useful check without
admin: without a NOPASSWD rule it just fails with "a password is required",
and a full listing needs an elevation window.

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
# Force a sync if it lingers. Root-only: needs an Admin By Request window.
sudo launchctl kickstart -k system/com.jumpcloud.darwin-agent
```

Without a window, just wait: the agent re-syncs on its own schedule.

Trade-off: deleting the key revokes remote repair entirely, even inside a
window. If you want to keep the workflow, leave the key in place — the on-demand
tunnel + no-unattended-root posture already contains the risk. Re-add a key in
JumpCloud if you ever need to restore access after deleting it.

## Scrubbing note

This is a public repo. Do NOT hardcode the GCP project name, cloudbox's public
IP (use `$CLOUDBOX_IP` / `gcloud`), any corporate email, or a JumpCloud org/SSO
URL here. See the `scrubbing-company-references` skill.
