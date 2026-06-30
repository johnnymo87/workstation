{ pkgs, opencode, k }:

pkgs.writeShellApplication {
  name = "oc-pool-attach";
  runtimeInputs = [ pkgs.curl pkgs.jq pkgs.gnugrep pkgs.coreutils ];
  text = ''
    classify_oc_invocation() {
      local subcmds="completion acp mcp attach run debug providers auth agent upgrade uninstall serve web models stats export import github pr session plugin plug db"
      local sid="" project="" have_session=0 positionals=0 first_pos_checked=0 a
      while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
          --) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          -s|--session)
            shift
            if [ $# -eq 0 ] || [ -z "$1" ] || [ "$have_session" -eq 1 ]; then printf 'PASSTHROUGH\t\t\n'; return 0; fi
            sid="$1"; have_session=1; shift ;;
          --session=*)
            if [ "$have_session" -eq 1 ]; then printf 'PASSTHROUGH\t\t\n'; return 0; fi
            sid="''${a#--session=}"; have_session=1; shift ;;
          -s*)
            if [ "$have_session" -eq 1 ]; then printf 'PASSTHROUGH\t\t\n'; return 0; fi
            sid="''${a#-s}"; have_session=1; shift ;;
          --model|-m|--agent|--prompt|--port|--hostname|--mdns|--cors|-c|--continue|--fork|--pure|-h|--help|-v|--version|--print-logs|--log-level) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          --model=*|--agent=*|--prompt=*|--port=*|--hostname=*|--cors=*|--log-level=*|--mdns=*) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          -*) printf 'PASSTHROUGH\t\t\n'; return 0 ;;
          *)
            if [ "$first_pos_checked" -eq 0 ]; then
              first_pos_checked=1
              for sc in $subcmds; do [ "$a" = "$sc" ] && { printf 'PASSTHROUGH\t\t\n'; return 0; }; done
            fi
            positionals=$((positionals+1)); project="$a"; shift ;;
        esac
      done
      [ "$positionals" -gt 1 ] && { printf 'PASSTHROUGH\t\t\n'; return 0; }
      if [ "$have_session" -eq 1 ]; then
        printf '%s' "$sid" | grep -Eq '^ses_[A-Za-z0-9_-]+$' || { printf 'PASSTHROUGH\t\t\n'; return 0; }
        printf 'RESUME\t%s\t%s\n' "$sid" "$project"; return 0
      fi
      printf 'NEW\t\t%s\n' "$project"; return 0
    }
  '';
}
