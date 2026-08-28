{ pkgs }:

# lgtm-gh: identity-resolving `gh` wrapper for lgtm's multi-reviewer feature.
#
# A dispatched (headless) OpenCode review session is told to use `lgtm-gh`
# instead of `gh` for any GitHub state-changing operation. This wrapper reads
# the reviewer login that lgtm wrote into the worktree's `.lgtm-reviewer`,
# resolves that login's classic PAT at `~/.config/lgtm/tokens/<login>.pat`
# (deployed from sops on cloudbox), and execs `gh` with `GH_TOKEN` set so the
# review posts under that identity. The token never enters the agent's
# reasoning context — the agent only ever sees the identity *name*.
#
# It ALSO records the id of every review artifact it creates, to a JSONL
# ledger. See "Why the ledger exists" below.
#
# Design: lgtm repo docs/plans/2026-04-30-multi-reviewer-identity-design.md.
# Behavior is locked by pkgs/lgtm-gh/test.sh.
pkgs.writeShellApplication {
  name = "lgtm-gh";
  # coreutils: cat/tr/env/date/mktemp. gh: the wrapped CLI itself, pinned so
  # the wrapper works even under a restricted systemd PATH. jq: parses the id
  # out of gh's response and emits the ledger line. writeShellApplication
  # prepends these to PATH (it does not clobber the inherited PATH).
  runtimeInputs = [ pkgs.coreutils pkgs.gh pkgs.jq ];
  text = ''
    # Identity for this worktree: a single GitHub login lgtm wrote here.
    login_file="$PWD/.lgtm-reviewer"
    if [ ! -r "$login_file" ]; then
      echo "lgtm-gh: missing $login_file" >&2
      exit 1
    fi

    login="$(tr -d '[:space:]' < "$login_file")"
    if [ -z "$login" ]; then
      echo "lgtm-gh: empty $login_file" >&2
      exit 1
    fi

    # Resolve that login's PAT. On cloudbox this file is materialized from a
    # sops secret by home.activation.deployLgtmTokens (chmod 600, owner dev).
    token_file="$HOME/.config/lgtm/tokens/$login.pat"
    if [ ! -r "$token_file" ]; then
      echo "lgtm-gh: missing $token_file for login=$login" >&2
      exit 1
    fi

    # ---- review-artifact ledger --------------------------------------------
    #
    # WHY THIS EXISTS. lgtm reviews as a POOL OF REAL HUMAN LOGINS
    # (johnnymo87, Krosantos, jamesvec), so its review comments are
    # indistinguishable from those humans' own comments: same login, same
    # __typename "User", no marker. The shepherd's needs_reply signal
    # therefore cannot tell "a human is waiting on the author" from "lgtm is
    # waiting on the author", and a wake budget can be spent entirely on lgtm
    # talking to an AI agent with no person anywhere in the loop.
    #
    # Identity cannot answer this and neither can time: Krosantos and jamesvec
    # are real colleagues who also review PRs themselves, so correlating by
    # (login, time window) misclassifies a real human as machine -- the
    # expensive direction. The only reliable discriminator is the ARTIFACT ID,
    # because every artifact lgtm creates is created HERE, and a human posting
    # from a browser never passes through this wrapper.
    #
    # FAILS TOWARD HUMAN, ALWAYS. Any failure below (no jq, unparseable body,
    # unwritable state dir, non-numeric id) leaves the artifact UNRECORDED,
    # and an unrecorded artifact is read downstream as a human's. That is the
    # safe direction: at worst we spend a wake answering a machine, whereas
    # the inverse silently erases evidence that a person was engaged.
    #
    # It must NEVER break the underlying call. Recording is best-effort and
    # the exit code always comes from gh.
    ledger_dir="$HOME/.local/state/lgtm"
    ledger_file="$ledger_dir/review-artifacts.jsonl"

    # Does this invocation CREATE a review artifact whose id we must record?
    # Sets `matched_endpoint` as a side effect. Note `gh api` implies POST as
    # soon as any -f/-F field is present, so requiring an explicit `-X POST`
    # would miss exactly the calls the prompt tells agents to make.
    matched_endpoint=""
    is_review_post() {
      local a endpoint="" posty=0 prev=""
      for a in "$@"; do
        case "$a" in
          -f|-F|--field|--raw-field) posty=1 ;;
          POST|post) if [ "$prev" = "-X" ] || [ "$prev" = "--method" ]; then posty=1; fi ;;
        esac
        case "$a" in
          */pulls/*/reviews|*/pulls/*/comments|*/pulls/comments/*/replies)
            endpoint="$a" ;;
        esac
        prev="$a"
      done
      if [ -n "$endpoint" ] && [ "$posty" -eq 1 ]; then
        matched_endpoint="$endpoint"
        return 0
      fi
      return 1
    }

    record_artifact() {
      local endpoint="$1" body_file="$2" id kind ts
      mkdir -p "$ledger_dir" 2>/dev/null || {
        echo "lgtm-gh: cannot create $ledger_dir; artifact unrecorded (reads as human)" >&2
        return 0
      }
      id="$(jq -r '.id? // empty' < "$body_file" 2>/dev/null || true)"
      case "$id" in
        ""|*[!0-9]*)
          echo "lgtm-gh: no numeric id in response; artifact unrecorded (reads as human)" >&2
          return 0 ;;
      esac
      case "$endpoint" in
        */reviews)  kind="review" ;;
        */replies)  kind="reply" ;;
        *)          kind="comment" ;;
      esac
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      # One line, one write: an O_APPEND write of a short line is atomic
      # enough for concurrent reviewers appending to the same ledger.
      jq -cn \
        --arg ts "$ts" --arg login "$login" --arg endpoint "$endpoint" \
        --arg kind "$kind" --argjson id "$id" \
        '{ts:$ts, login:$login, endpoint:$endpoint, kind:$kind, id:$id}' \
        >> "$ledger_file" 2>/dev/null \
        || echo "lgtm-gh: ledger append failed; artifact unrecorded (reads as human)" >&2
      return 0
    }

    # Everything that is not a review-creating POST keeps the original exec
    # path verbatim: same process replacement, same streaming, no capture.
    # This wrapper mediates EVERY state-changing call lgtm makes, so the
    # deviation below is confined to the calls whose ids we actually need.
    if ! is_review_post "$@"; then
      # exec so GH_TOKEN lives only for gh's lifetime; the agent never sees it.
      exec env GH_TOKEN="$(cat "$token_file")" gh "$@"
    fi

    # Capture path. stdout is buffered to a temp file so the id can be read
    # out of it, then replayed byte-for-byte; stderr is untouched and gh's
    # exit code is preserved exactly.
    tmp="$(mktemp 2>/dev/null)" || exec env GH_TOKEN="$(cat "$token_file")" gh "$@"
    rc=0
    set +o errexit
    env GH_TOKEN="$(cat "$token_file")" gh "$@" > "$tmp"
    rc=$?
    set -o errexit
    cat "$tmp"
    # Only a successful call created an artifact worth recording.
    if [ "$rc" -eq 0 ]; then
      record_artifact "$matched_endpoint" "$tmp"
    fi
    rm -f "$tmp"
    exit "$rc"
  '';
}
