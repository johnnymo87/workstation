#!/usr/bin/env bash
# Stand-in for lgtm's scripts/lgtm-gh/lgtm-gh.sh in test.sh: reports what the
# launcher handed it, then exits with $FIXTURE_RC.
printf 'ARGC=%s\n' "$#"
i=0; line=""
for a in "$@"; do i=$((i + 1)); line="${line:+$line|}ARG$i=$a"; done
printf '%s\n' "$line"
printf 'STDIN=%s\n' "$(cat)"
printf 'GH=%s\n' "$(command -v gh)"
for tool in jq node tr timeout; do printf '%s=%s\n' "$tool" "$(command -v "$tool")"; done
printf 'PATH=%s\n' "$PATH"
exit "${FIXTURE_RC:-0}"
