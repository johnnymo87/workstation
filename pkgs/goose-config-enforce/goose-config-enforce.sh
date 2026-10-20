#!/usr/bin/env bash
# goose-config-enforce <config.yaml> <policy.json>
#
# Make the `enabled` flag of each extension named in <policy.json> match the
# policy, in goose's writable ~/.config/goose/config.yaml, and touch nothing
# else.
#
# Why not a home-manager symlink: goose WRITES this file (`goose configure`,
# extension toggles, plugin discovery, its own config migrations), so a
# read-only store link would break it, and the file also holds imperative
# provider state. So the file stays mutable and this runs on every switch.
#
# policy.json: {"extensions": {"<config key>": true|false, ...}}
#
# Behaviour:
#   - Only `.extensions.<key>.enabled` is written. Every other field and every
#     other top-level key is left as it is.
#   - A key with no entry (or a non-mapping entry) gets `{enabled: <bool>}`,
#     with a warning: it is either a typo in the policy or a host where goose
#     has not written its entries yet. goose's own migration
#     (config/migrations.rs) completes a real platform entry on its next load
#     and keeps the `enabled` it finds; an unknown key is ignored by goose.
#   - If every flag already matches, the file is not rewritten (no mtime churn).
#   - A MISSING file is left missing (exit 0 with a note): creating one would
#     make goose skip its first-run onboarding (it keys that off the file
#     existing) and hide goose-serve's preflight. The next switch after goose
#     has created it enforces the policy.
#   - A symlink is followed and its TARGET is rewritten, as goose does
#     (config_write_target_path), so the link survives with the target's mode.
#   - A file that is not a single YAML mapping (unparseable, multi-document,
#     scalar root, non-mapping `extensions:`) or a policy that is not
#     {extensions: {k: bool}} is a non-zero exit with the file untouched.
#   - Writes go to a temp file in the same directory, then mv, so goose never
#     reads a half-written file. goose has no cross-process lock, so if the
#     file changes while the new copy is being made, the attempt is discarded
#     and redone (up to 3 times) rather than overwriting goose's write.
set -euo pipefail

prog="goose-config-enforce"
if [ "$#" -ne 2 ]; then
  echo "usage: $prog <config.yaml> <policy.json>" >&2
  exit 64
fi
policy="$2"

if ! jq -e '
      (.extensions | type == "object")
      and (.extensions | to_entries | all(.value | type == "boolean"))
    ' "$policy" >/dev/null 2>&1; then
  echo "$prog: $policy is not {\"extensions\": {name: true|false}}; nothing changed" >&2
  exit 65
fi

if [ ! -e "$1" ]; then
  echo "$prog: $1 does not exist yet; nothing to enforce (goose creates it on first run)"
  exit 0
fi
cfg="$(readlink -f -- "$1")"
if [ ! -f "$cfg" ]; then
  echo "$prog: $1 does not resolve to a regular file; nothing changed" >&2
  exit 65
fi

check_shape() {
  local docs
  docs="$(yq ea '[.] | length' "$cfg" 2>/dev/null)" || return 1
  [ "$docs" = 1 ] || return 1
  # Two separate calls on purpose: yq-go's `or`/`and` mis-evaluate here (`or`
  # binds tighter than `==`, and `and` is false when `.extensions` is absent).
  yq -e 'tag | test("^!!(map|null)$")' "$cfg" >/dev/null 2>&1 || return 1
  yq -e '.extensions | tag | test("^!!(map|null)$")' "$cfg" >/dev/null 2>&1
}
if ! check_shape; then
  echo "$prog: $cfg is not a single YAML mapping with a mapping (or absent) extensions:; nothing changed" >&2
  exit 65
fi

# Policy entries whose flag differs from the file: {"name": bool, ...}.
# Not `.enabled // ...`: yq's `//` treats false as missing.
current="$(yq -o=json '
  .extensions // {} | with_entries(.value |= (select(tag == "!!map") | .enabled | select(tag == "!!bool")))
' "$cfg")"
# (jq's `//` treats false as missing too, hence the explicit type test.)
changes="$(jq -c --argjson cur "$current" '
  .extensions | with_entries(select(($cur[.key] | type) != "boolean" or $cur[.key] != .value))
' "$policy")"
created="$(jq -r --argjson cur "$current" '
  .extensions | keys[] | select(($cur[.] | type) != "boolean")
' "$policy")"

if [ "$changes" = "{}" ]; then
  echo "$prog: $cfg unchanged"
  exit 0
fi
for name in $created; do
  echo "$prog: WARNING: no entry for '$name' in $cfg; adding {enabled: ...}. If this is not a goose extension key it is a typo in the policy and has no effect." >&2
done

dir="$(dirname "$cfg")"
mode="$(stat -c '%a' "$cfg")"
tmp=""
trap 'rm -f "$tmp"' EXIT
for attempt in 1 2 3; do
  before="$(sha256sum < "$cfg")"
  tmp="$(mktemp "$dir/.goose-config-enforce.XXXXXX")"
  cat "$cfg" > "$tmp"
  CH="$changes" yq -i '
    (strenv(CH) | from_json) as $ch
    | .extensions = (.extensions // {})
    | ($ch | to_entries | .[]) as $i ireduce (.;
        .extensions[$i.key] |= (select(tag == "!!map") // {} | .enabled = $i.value))
  ' "$tmp"
  chmod "$mode" "$tmp"
  if [ "$(sha256sum < "$cfg")" = "$before" ]; then
    mv -f "$tmp" "$cfg"
    tmp=""
    trap - EXIT
    echo "$prog: $cfg set $(jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"$changes")"
    exit 0
  fi
  rm -f "$tmp"
  tmp=""
  echo "$prog: $cfg changed while being updated (attempt $attempt); retrying" >&2
done
echo "$prog: $cfg kept changing under us; gave up without writing" >&2
exit 75
