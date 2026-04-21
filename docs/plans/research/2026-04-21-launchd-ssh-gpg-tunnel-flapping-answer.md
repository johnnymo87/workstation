My recommendation is:

**For Git commit/tag signing, switch to SSH signing backed by the 1Password SSH agent, and stop using GPG-agent socket forwarding for that purpose.** Keep GPG on the Mac for anything that is actually OpenPGP-specific, but don’t make remote Git signing depend on a forwarded GPG socket unless you truly need PGP signatures on the commits themselves. Git supports SSH signing, GitHub verifies SSH-signed commits, 1Password officially supports both SSH commit signing and SSH agent forwarding with local biometric approval, and GitHub explicitly describes SSH as the simpler option while noting that GPG has extra features such as expiry/revocation semantics. ([GitHub Docs][1])

If you **must** keep the current GPG architecture, it can be made much better, but the brittleness you are seeing is real and comes from three separate layers: a non-portable Apple-only SSH option in a config consumed by vanilla OpenSSH, GnuPG on the remote wanting to recreate `S.gpg-agent` itself, and the fact that `StreamLocalBindUnlink` only cleans up an old socket pathname **before bind**. It is not a liveness mechanism and it does not “heal” a dead forward later. ([Apple Developer][2])

On your first question, I do **not** think this is fundamentally a `launchd` environment quirk. Upstream OpenSSH documents the parse order as: command-line options, then `~/.ssh/config`, then system config; it also says the **first obtained value** wins, so host-specific blocks belong near the beginning and general defaults near the end. Separately, `IgnoreUnknown` is documented as something that should be listed **early in the config file**, and Apple’s own compatibility guidance for `UseKeychain` is to put `IgnoreUnknown UseKeychain` in the config **before** `UseKeychain yes`. That is the documented compatibility pattern; `-o IgnoreUnknown=UseKeychain` is not the pattern Apple shows. So I would treat your command-line workaround as unsupported-at-best, not as something you should keep depending on. Also, your `Host *` block at the top is non-canonical for OpenSSH’s first-value-wins semantics. ([Man Pages][3])

That also means this part should be corrected bluntly: **if the same nix OpenSSH binary is really reading the same config file, parse success should be deterministic.** A fixed binary does not sometimes accept and sometimes reject the same unknown config keyword because of `$TERM` or `PATH`. So the intermittent success strongly suggests one of these is false in practice: the interactive shell is not always using the same binary, the launchd job is not always reading the same config path, or your config generator is sometimes rewriting the file in a different form or non-atomically. The log path already shows the launchd process is reading the shared `~/.ssh/config`, so the simplest fix is to stop doing that for the tunnel jobs entirely. ([Man Pages][3])

For the tunnel itself, `launchd` supervising plain `ssh -NT` is a perfectly reasonable architecture on macOS; I would **not** reach for `autossh` first. `launchd` already has keepalive/restart semantics and throttling, and OpenSSH already has protocol-level liveness checks. `launchd`’s `KeepAlive` can be unconditional or keyed to conditions such as `NetworkState`; `ThrottleInterval` controls restart pacing; and OpenSSH’s `ServerAliveInterval` / `ServerAliveCountMax` handles dead sessions. Also, background SSH should use `StdinNull`/`-n`, and `ExitOnForwardFailure=yes` only covers failure to establish the forward in the first place — it does **not** cause SSH to exit later just because a connection through the forward failed. So your repeated tunnel deaths are much more likely to be config-parse and network events than “local GPG socket disappeared during one forwarded use.” ([Manpagez][4])

The “stale socket on remote” problem has a much more specific explanation than just “SSH didn’t clean up.” GnuPG’s own forwarding docs say that the local `extra` socket is the intended thing to forward, but they also warn that remote `gpg` will try to autostart `gpg-agent`, and that the remote `gpg-agent` can delete your forwarded socket and create its own unless you use `--no-autostart`. Upstream GnuPG goes further: it says systemd socket activation conflicts with this remote-use pattern and can make `no-autostart` ineffective, recommending masking the user `gpg-agent*.socket` and related units if systemd is managing them. That is very likely the core of your “socket file exists but doesn’t route anywhere useful” failure mode. ([GnuPG Wiki][5])

So if you stay with GPG forwarding, the minimum serious fix is this:

```sshconfig
# ~/.ssh/config   (or better: move the tunnel hosts to a dedicated file)
IgnoreUnknown UseKeychain

Host devbox-gpg-tunnel
  HostName ...
  User dev
  IdentityAgent /Users/<user>/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
  StdinNull yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ConnectTimeout 10
  ConnectionAttempts 1
  RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/<user>/.gnupg/S.gpg-agent.extra

Host cloudbox-gpg-tunnel
  HostName ...
  User dev
  IdentityAgent /Users/<user>/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
  StdinNull yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ConnectTimeout 10
  ConnectionAttempts 1
  RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/<user>/.gnupg/S.gpg-agent.extra

Host *
  AddKeysToAgent yes
  # UseKeychain yes   # only if you still need Apple keychain for file-backed SSH keys
  IdentityAgent /Users/<user>/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
```

And for the **launchd** job, I would stop reading the shared config entirely and instead point the tunnel job at a dedicated, vanilla-safe config with `-F`, or even `-F none` plus explicit `-o` flags. OpenSSH explicitly supports `-F` for an alternate per-user config and `-F none` to ignore config files entirely. That one change eliminates the `UseKeychain` parse class of failure completely. ([Man Pages][6])

On the Linux side, if you keep GPG forwarding, add `no-autostart` to the remote GnuPG config for the dev user, and if those NixOS machines have user-level GnuPG sockets/services managed by systemd, disable or mask them for that user so they stop recreating `S.gpg-agent` behind SSH’s back. Also use `gpgconf --list-dir agent-socket` and `gpgconf --list-dir agent-extra-socket` instead of hard-coding paths; that is what the GnuPG docs recommend. If `/run/user/<uid>/gnupg` is being cleaned up on logout on those systems, GnuPG’s wiki calls that out too and suggests recreating the socket dir. ([GnuPG Wiki][5])

I would also drop `UseKeychain` unless you still have ordinary file-backed SSH keys whose **passphrases** you want Apple’s SSH to stash in the macOS keychain. Apple describes `UseKeychain` specifically in terms of storing SSH key passphrases in the keychain. But your actual active SSH identity path is a 1Password agent socket via `IdentityAgent`, and 1Password says the private key never leaves the app and approvals happen through the app’s own authorization flow. Those are separate mechanisms, so in your current setup `UseKeychain` is probably just dead weight and a portability footgun. ([Apple Developer][2])

If you switch to **SSH signing**, the remote setup gets much simpler. Git supports `gpg.format=ssh`; signatures become SSH signatures; local verification uses `gpg.ssh.allowedSignersFile`; and Git says SSH has no GPG-style trust levels, so trust is based on the allowed-signers file (or a CA-based scheme). GitHub verifies SSH-signed commits the same way it verifies GPG-signed ones. The trade-off is not “verified vs not verified”; it is mainly **PGP trust model vs allowed-signers trust model**. GPG gives you native expiry/revocation/web-of-trust-ish machinery; SSH gives you a flatter, file-based trust setup that is operationally simpler but less feature-rich. Git does at least support validity windows in `allowedSignersFile` since OpenSSH 8.8, which helps with key rotation. ([GitHub Docs][1])

A minimal remote Git config for SSH signing looks like this:

```ini
[gpg]
    format = ssh
[user]
    signingkey = key::ssh-ed25519 AAAA... your-email@example.com
[commit]
    gpgsign = true
[gpg "ssh"]
    allowedSignersFile = ~/.config/git/allowed_signers
```

If you only need signing inside interactive SSH sessions, standard SSH agent forwarding is enough and 1Password officially supports that pattern for remote workstations and cloud dev environments. If you truly need a **stable, headless remote socket** for jobs that are not children of an interactive SSH session, then the same basic tunnel shape you have now still makes sense — but forward the **1Password SSH agent socket** to a stable remote path and use SSH signing there, instead of forwarding the GPG extra socket. That part is an architectural inference from the documented SSH-agent-forwarding model, not something 1Password documents in exactly that `RemoteForward /path /path` form. But it removes GnuPG-from-the-remote entirely, which is the main source of your current flapping/staleness pain. 1Password also explicitly warns to do this only with trusted hosts, because remote same-user processes can ask the forwarded agent to authenticate during the authorized session. ([1Password Developer][7])

So the practical verdict is:

**Best overall:** move Git signing to SSH signing with 1Password.
**Best if you must keep GPG:** dedicated tunnel-only SSH config, remove or isolate `UseKeychain`, disable remote GnuPG autostart/socket activation, and keep launchd supervising plain `ssh -NT`.
**What I would not do:** `op`-based private-key use on the remote, smartcard/scdaemon forwarding unless you specifically need a hardware token workflow, or storing the private key on the Linux boxes. Those are all worse fits for the constraints you gave. ([1Password Developer][8])

If you want, I can turn this into a concrete nix-darwin + home-manager plan with a tunnel-only `ssh_config`, a `launchd` plist stanza, and the remote NixOS changes for either the **fixed GPG** path or the **SSH-signing** path.

[1]: https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification "https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification"
[2]: https://developer.apple.com/library/archive/technotes/tn2449/_index.html "https://developer.apple.com/library/archive/technotes/tn2449/_index.html"
[3]: https://man.openbsd.org/ssh_config "https://man.openbsd.org/ssh_config"
[4]: https://www.manpagez.com/man/5/launchd.plist/ "https://www.manpagez.com/man/5/launchd.plist/"
[5]: https://wiki.gnupg.org/AgentForwarding "https://wiki.gnupg.org/AgentForwarding"
[6]: https://man.openbsd.org/ssh.1 "https://man.openbsd.org/ssh.1"
[7]: https://developer.1password.com/docs/ssh/agent/forwarding/ "https://developer.1password.com/docs/ssh/agent/forwarding/"
[8]: https://developer.1password.com/docs/ssh/git-commit-signing/ "https://developer.1password.com/docs/ssh/git-commit-signing/"

