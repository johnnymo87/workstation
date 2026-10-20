#!/usr/bin/env bash
# goose-config-enforce <config.yaml> <policy.json>
#
# Make the `enabled` flag of each extension named in <policy.json> match the
# policy, in goose's writable ~/.config/goose/config.yaml, and touch nothing
# else.
#
# Why not a home-manager symlink: goose WRITES this file (`goose configure`,
# extension toggles, its own config migrations), so a read-only store link
# would break it, and the file also holds imperative provider state. So the
# file stays mutable and this runs on every switch, so the policy is applied
# again on each switch.
#
# policy.json: {"extensions": {"<config key>": true|false, ...}}
#
# Behaviour:
#   - Only `.extensions.<key>.enabled` is written. Every other field and every
#     other top-level key is left as it is.
#   - A key with no entry (or a non-mapping entry) gets `{enabled: <bool>}`.
#     goose's own migration (config/migrations.rs) completes a platform entry
#     on its next load and keeps the `enabled` it finds.
#   - If every flag already matches, the file is not rewritten (no mtime churn).
#   - A missing file is created (mode 600) holding only the policy.
#   - An unparseable file or a policy that is not {extensions: {k: bool}} is a
#     non-zero exit with the file untouched.
#   - Writes go to a temp file in the same directory, then mv, so goose never
#     reads a half-written file. The original mode is kept.
set -euo pipefail

prog="goose-config-enforce"
if [ "$#" -ne 2 ]; then
  echo "usage: $prog <config.yaml> <policy.json>" >&2
  exit 64
fi
cfg="$1"
policy="$2"

if ! jq -e '
      (.extensions | type == "object")
      and (.extensions | to_entries | all(.value | type == "boolean"))
    ' "$policy" >/dev/null 2>&1; then
  echo "$prog: $policy is not {\"extensions\": {name: true|false}}; nothing changed" >&2
  exit 65
fi

created=0
if [ ! -e "$cfg" ]; then
  mkdir -p "$(dirname "$cfg")"
  created=1
elif ! yq -e 'tag == "!!map" or tag == "!!null"' "$cfg" >/dev/null 2>&1; then
  echo "$prog: cannot parse $cfg as a YAML mapping; nothing changed" >&2
  exit 65
fi

# Names whose flag differs from the policy, as "name=bool".
changes=()
while IFS=$'\t' read -r name want; do
  [ -n "$name" ] || continue
  have="absent"
  if [ "$created" -eq 0 ]; then
    # Not `.enabled // "absent"`: yq's `//` treats false as missing.
    have="$(NAME="$name" yq -r '
      .extensions[strenv(NAME)] | select(tag == "!!map") | .enabled | select(tag == "!!bool")
    ' "$cfg" 2>/dev/null || true)"
    have="${have:-absent}"
  fi
  if [ "$have" != "$want" ]; then
    changes+=("$name=$want")
  fi
done < <(jq -r '.extensions | to_entries[] | "\(.key)\t\(.value)"' "$policy")

if [ "${#changes[@]}" -eq 0 ]; then
  echo "$prog: $cfg unchanged"
  exit 0
fi

dir="$(dirname "$cfg")"
tmp="$(mktemp "$dir/.goose-config-enforce.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

if [ "$created" -eq 1 ]; then
  printf '{}\n' > "$tmp"
  mode=600
else
  cat "$cfg" > "$tmp"
  mode="$(stat -c '%a' "$cfg")"
fi

for change in "${changes[@]}"; do
  name="${change%=*}"
  want="${change#*=}"
  NAME="$name" WANT="$want" yq -i '
    (.extensions // {}) as $e
    | .extensions = $e
    | (select((.extensions[strenv(NAME)] | tag) != "!!map") | .extensions[strenv(NAME)]) = {}
    | .extensions[strenv(NAME)].enabled = (strenv(WANT) == "true")
  ' "$tmp"
done

chmod "$mode" "$tmp"
mv -f "$tmp" "$cfg"
trap - EXIT
echo "$prog: $cfg set ${changes[*]}"
