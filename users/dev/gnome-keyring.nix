# Headless D-Bus Secret Service (org.freedesktop.secrets) for libsecret clients.
#
# WHY THIS EXISTS
#   libsecret-based tools store their credentials in the D-Bus Secret Service
#   (org.freedesktop.secrets), which on a normal desktop is provided by
#   gnome-keyring's `secrets` component and auto-unlocked at graphical login by
#   pam_gnome_keyring. On a HEADLESS box (devbox/cloudbox: SSH only, no greeter,
#   no PAM keyring integration) there is no such daemon and no unlock, so the
#   name org.freedesktop.secrets is unregistered. The concrete casualty is the
#   `clerk` CLI (pkgs/clerk): `clerk auth login` reports success but silently
#   fails to persist its OAuth token (no secret service to write to), so every
#   later `clerk config pull/patch` dies with "Session expired". Any other
#   libsecret/keyring client (git-credential-libsecret, etc.) has the same gap.
#
# WHY NOT home-manager's `services.gnome-keyring.enable`
#   That module is desktop-oriented and unusable here on two counts:
#     1. ExecStart is `gnome-keyring-daemon --start --foreground` with NO
#        `--unlock` — the login keyring is created LOCKED, and with no prompt
#        agent on a headless box libsecret writes just fail.
#     2. Install/PartOf target is `graphical-session-pre.target`, which never
#        starts on an SSH-only host, so the service never runs at all.
#   So we run a purpose-built unit that mirrors the proven headless incantation
#   (`--foreground --unlock --components=secrets`, empty password on stdin).
#
# HEADLESS VIABILITY
#   `users.users.dev.linger = true` (hosts/*/configuration.nix) keeps
#   user@1000.service (and its default.target + dbus.socket) up at boot with no
#   interactive login, so a WantedBy=default.target user unit starts at boot.
#
# SECURITY POSTURE (auto-unlock; see PR description for the full writeup)
#   The keyring is auto-unlocked with an EMPTY password by default. On this
#   single-user personal box every workload already runs as `dev` and can
#   already read /run/secrets/* (0400), ~/.config/gws/credentials.json (0600),
#   etc., so auto-unlock does not widen the *runtime* attack surface. The only
#   thing an empty password weakens is *at-rest* protection of
#   ~/.local/share/keyrings/login.keyring (which is NOT in /persist and is
#   reconstructable). To harden at-rest without any other change, drop a sops
#   secret `gnome_keyring_password` at /run/secrets/ (tmpfs, never on disk) and
#   this unit will encrypt the keyring with it instead of the empty password.
{ config, pkgs, lib, isLinux, ... }:

lib.mkIf isLinux {
  # gnome-keyring: the daemon (referenced by store path below, but handy in PATH
  # for debugging). libsecret: `secret-tool` for manual store/lookup round-trips.
  home.packages = [ pkgs.gnome-keyring pkgs.libsecret ];

  systemd.user.services.gnome-keyring-secrets = {
    Unit = {
      Description = "GNOME Keyring headless Secret Service (org.freedesktop.secrets)";
      Documentation = [ "man:gnome-keyring-daemon(1)" ];
      # The session bus must exist before we can claim a bus name on it.
      Requires = [ "dbus.socket" ];
      After = [ "dbus.socket" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.writeShellScript "gnome-keyring-secrets-start" ''
        set -euo pipefail
        # Auto-unlock password: use the sops secret if present, else empty.
        # --unlock reads one line from stdin and uses it to CREATE (first boot)
        # or UNLOCK (subsequent boots) the login keyring, so the keyring file
        # persists across reboots and the same password is reused.
        pw=""
        if [ -r /run/secrets/gnome_keyring_password ]; then
          pw="$(cat /run/secrets/gnome_keyring_password)"
        fi
        # --foreground: run as the systemd main process (Type=simple), do not
        #   fork; systemd owns the lifecycle and the cgroup.
        # --unlock: read the password from stdin (piped below).
        # --components=secrets: ONLY the Secret Service — no ssh-agent / pkcs11,
        #   which would otherwise fight the existing SSH setup.
        # A second instance started while another daemon already owns the name
        # just idles with a "another secret service is running" message and does
        # NOT steal the name (no --replace), so this is safe to (re)start.
        printf '%s\n' "$pw" | ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon \
          --foreground --unlock --components=secrets
      ''}";
      # A genuine crash (not the benign name-already-owned idle) should recover.
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
