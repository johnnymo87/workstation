# goose-link: the only tool that moves /var/lib/goose/current, the approved
# goose binary every goose on a NixOS host runs (bead workstation-6w7i.27.2, L6;
# modules/goose-current.nix creates the link and its GC roots).
#
#   goose-link status            current / previous / pinned, and whether they match
#   goose-link set <store-path>  previous := current; current := <store-path>
#   goose-link pinned            set to what /etc/goose/pinned (the merged pin) resolves to
#   goose-link rollback          swap current and previous
#
# It restarts nothing. The flip takes effect for the CLI at once (each `goose`
# resolves the link when it starts) and for goose-serve at its next restart:
#   sudo goose-link rollback && sudo systemctl restart goose-serve
# A restart ends every goose turn on the host; pick a quiet window (the cutover,
# L3a, does). Root only: /var/lib/goose is root's, which is what keeps a goose
# session from moving its own binary.
#
# A rollback moves the BINARY only. Config that the pin gates (the version
# asserts in users/dev/goose-config.nix, goose-roles validated against the pin)
# stays at the merged pin until a revert of the pin PR merges and is switched:
# switching to an older generation does not stick, because pull-workstation
# re-applies origin/main on its timer (and cloudbox's hm-deploy-gate refuses a
# stale generation). So a rollback is: flip, restart, then revert the pin PR.
#
# `set` takes only a /nix/store path whose bin/goose is an ELF binary, so it
# cannot be pointed at the profile's wrapper (which execs this link: a loop
# goose-serve's preflight passes and Restart=always never ends).
# Each link is replaced atomically (a temp link renamed over it with mv -T), so
# a goose starting mid-flip sees the old target or the new one, never none.
# GOOSE_LINK_DIR, GOOSE_PINNED and GOOSE_LINK_STORE override the paths, for
# pkgs/goose-link/test.sh.
{ writeShellApplication, coreutils }:

writeShellApplication {
  name = "goose-link";
  runtimeInputs = [ coreutils ];
  text = ''
    dir="''${GOOSE_LINK_DIR:-/var/lib/goose}"
    pinned_link="''${GOOSE_PINNED:-/etc/goose/pinned}"
    store="''${GOOSE_LINK_STORE:-/nix/store}"

    usage() {
      echo "usage: goose-link status | set <store-path> | pinned | rollback" >&2
      exit 2
    }

    target() { readlink "$dir/$1" 2>/dev/null || echo "<none>"; }

    runnable() { [ -x "$1/bin/goose" ] && [ ! -d "$1/bin/goose" ]; }

    # A real goose: a store path whose bin/goose is an ELF file, not a script.
    is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }

    # Replace link $1 (a name in $dir) with a symlink to $2, atomically.
    put() {
      local tmp
      tmp="$dir/.goose-link.$1.$$"
      ln -sfn "$2" "$tmp"
      mv -fT "$tmp" "$dir/$1"
    }

    do_set() {
      local new cur
      case "$1" in
        /*) ;;
        *) echo "goose-link: $1 is not an absolute path" >&2; exit 2 ;;
      esac
      new="$(readlink -f "$1")" || { echo "goose-link: cannot resolve $1" >&2; exit 2; }
      case "$new" in
        "$store"/*) ;;
        *) echo "goose-link: $new is not under $store; refusing" >&2; exit 2 ;;
      esac
      if ! runnable "$new"; then
        echo "goose-link: $new/bin/goose is not an executable file; refusing" >&2
        exit 2
      fi
      if ! is_elf "$new/bin/goose"; then
        echo "goose-link: $new/bin/goose is not an ELF binary (a wrapper script?); refusing" >&2
        exit 2
      fi
      cur="$(target current)"
      if [ "$cur" = "$new" ]; then
        echo "goose-link: current is already $new"
        return 0
      fi
      if [ "$cur" != "<none>" ]; then
        put previous "$cur"
      fi
      put current "$new"
      echo "goose-link: current=$new (previous=$cur); restart goose-serve for the serve to run it"
    }

    cmd="''${1:-}"
    case "$cmd" in
      status)
        cur="$(target current)"
        pin="$(readlink -f "$pinned_link" 2>/dev/null || echo "<none>")"
        echo "current=$cur"
        echo "previous=$(target previous)"
        echo "pinned=$pin"
        if [ "$cur" = "$pin" ]; then echo "pinned_is_current=yes"; else echo "pinned_is_current=no"; fi
        if [ "$cur" = "<none>" ] || ! runnable "$cur"; then
          echo "goose-link: $dir/current is missing or not runnable" >&2
          exit 1
        fi
        ;;
      set)
        [ $# -eq 2 ] || usage
        do_set "$2"
        ;;
      pinned)
        [ $# -eq 1 ] || usage
        if [ ! -e "$pinned_link" ]; then
          echo "goose-link: $pinned_link does not exist" >&2
          exit 2
        fi
        do_set "$(readlink -f "$pinned_link")"
        ;;
      rollback)
        [ $# -eq 1 ] || usage
        prev="$(target previous)"
        cur="$(target current)"
        if [ "$prev" = "<none>" ] || ! runnable "$prev"; then
          echo "goose-link: no runnable previous ($prev); nothing to roll back to" >&2
          exit 1
        fi
        put current "$prev"
        if [ "$cur" != "<none>" ]; then
          put previous "$cur"
        fi
        echo "goose-link: rolled back to current=$prev (previous=$cur); restart goose-serve for the serve to run it"
        ;;
      *) usage ;;
    esac
  '';
}
