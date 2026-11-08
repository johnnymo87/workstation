#!/usr/bin/env bash
# Stand-in for lgtm's scripts/lgtm-review in test.sh: reports what the
# launcher handed it, then exits with $FIXTURE_RC.
printf 'ARGC=%s\n' "$#"
i=0; line=""
for a in "$@"; do i=$((i + 1)); line="${line:+$line|}ARG$i=$a"; done
printf '%s\n' "$line"
printf 'STDIN=%s\n' "$(cat)"
exit "${FIXTURE_RC:-0}"
