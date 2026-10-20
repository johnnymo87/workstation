#!/usr/bin/env bash
# Tests for goose-config-enforce.sh. Run by checks.goose-config-enforce in
# flake.nix (needs yq-go, jq, coreutils on PATH).
#
# The script edits a file goose itself also writes, on every home-manager
# switch, so most of these cases are about what it must NOT touch: other
# extension fields, other top-level keys, a file it cannot parse, a policy it
# cannot trust, and a file whose enabled set already matches.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
enforce="$here/goose-config-enforce.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then ok; else bad "$desc"; fi
}
enabled_of() { yq -r ".extensions.\"$2\".enabled" "$1"; }

sample() {
  cat > "$1" <<'EOF'
GOOSE_MODE: smart_approve
extensions:
  analyze:
    enabled: true
    type: platform
    name: analyze
    description: 'Analyze code: overviews'
    display_name: Analyze
    bundled: true
  todo:
    enabled: false
    type: platform
    name: todo
    description: Enable a todo list
    display_name: Todo
    bundled: true
  summon:
    enabled: true
    type: platform
    name: summon
    description: Delegate tasks
    display_name: Summon
    bundled: true
  my-stdio:
    enabled: true
    type: stdio
    name: my-stdio
    cmd: /bin/true
    args: []
providers:
  gcp_vertex_ai:
    enabled: true
    model: claude-opus-5-5
active_provider: gcp_vertex_ai
plugins:
  /tmp/x/.agents/plugins/p:
    enabled: true
EOF
}
policy() { printf '%s' "$1" > "$work/policy.json"; }

# 1. flips both directions and names what it changed
cfg="$work/c1.yaml"; sample "$cfg"
policy '{"extensions":{"todo":true,"summon":false,"analyze":true}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "1 exit 0" test "$rc" -eq 0
check "1 todo now true" test "$(enabled_of "$cfg" todo)" = true
check "1 summon now false" test "$(enabled_of "$cfg" summon)" = false
check "1 analyze still true" test "$(enabled_of "$cfg" analyze)" = true
check "1 reports todo" grep -q 'todo=true' <<<"$out"
check "1 reports summon" grep -q 'summon=false' <<<"$out"
check "1 does not report unchanged analyze" bash -c '! grep -q "analyze=" <<<"$1"' _ "$out"

# 2. everything else is preserved
check "2 description kept" test "$(yq -r '.extensions.analyze.description' "$cfg")" = 'Analyze code: overviews'
check "2 display_name kept" test "$(yq -r '.extensions.todo.display_name' "$cfg")" = Todo
check "2 stdio extension untouched" test "$(yq -r '.extensions.my-stdio.cmd' "$cfg")" = /bin/true
check "2 GOOSE_MODE kept" test "$(yq -r '.GOOSE_MODE' "$cfg")" = smart_approve
check "2 providers kept" test "$(yq -r '.providers.gcp_vertex_ai.model' "$cfg")" = claude-opus-5-5
check "2 active_provider kept" test "$(yq -r '.active_provider' "$cfg")" = gcp_vertex_ai
check "2 plugins kept" test "$(yq -r '.plugins."/tmp/x/.agents/plugins/p".enabled' "$cfg")" = true

# 3. idempotent: a matching file is not rewritten at all
before="$(stat -c '%i %Y %s' "$cfg")"; sha_before="$(sha256sum "$cfg")"
sleep 1
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "3 exit 0" test "$rc" -eq 0
check "3 reports unchanged" grep -q 'unchanged' <<<"$out"
check "3 same inode/mtime/size" test "$(stat -c '%i %Y %s' "$cfg")" = "$before"
check "3 same bytes" test "$(sha256sum "$cfg")" = "$sha_before"

# 4. a policy entry with no config entry is created with only `enabled`
#    (goose's own migration fills in type/name/description on next load)
cfg="$work/c4.yaml"; sample "$cfg"
policy '{"extensions":{"chatrecall":true}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "4 exit 0" test "$rc" -eq 0
check "4 chatrecall created enabled" test "$(enabled_of "$cfg" chatrecall)" = true
check "4 created entry has only enabled" test "$(yq -r '.extensions.chatrecall | keys | join(",")' "$cfg")" = enabled

# 5. file mode is preserved on rewrite
cfg="$work/c5.yaml"; sample "$cfg"; chmod 0644 "$cfg"
policy '{"extensions":{"todo":true}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1
check "5 mode still 644" test "$(stat -c '%a' "$cfg")" = 644
chmod 0600 "$cfg"; policy '{"extensions":{"todo":false}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1
check "5 mode still 600" test "$(stat -c '%a' "$cfg")" = 600

# 6. missing file: created with just the policy, mode 600
cfg="$work/new/dir/config.yaml"
policy '{"extensions":{"todo":true,"summon":false}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "6 exit 0" test "$rc" -eq 0
check "6 file created" test -f "$cfg"
check "6 todo true" test "$(enabled_of "$cfg" todo)" = true
check "6 summon false" test "$(enabled_of "$cfg" summon)" = false
check "6 mode 600" test "$(stat -c '%a' "$cfg")" = 600

# 7. existing file without an extensions key: added, rest kept
cfg="$work/c7.yaml"; printf 'GOOSE_MODE: auto\n' > "$cfg"
policy '{"extensions":{"todo":true}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "7 exit 0" test "$rc" -eq 0
check "7 todo true" test "$(enabled_of "$cfg" todo)" = true
check "7 GOOSE_MODE kept" test "$(yq -r '.GOOSE_MODE' "$cfg")" = auto

# 8. unparseable YAML: non-zero exit, file byte-identical
cfg="$work/c8.yaml"; printf 'extensions:\n  todo: [unclosed\n' > "$cfg"
sha_before="$(sha256sum "$cfg")"
policy '{"extensions":{"todo":true}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "8 non-zero exit" test "$rc" -ne 0
check "8 file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 9. policy values must be booleans; a string "false" is refused
cfg="$work/c9.yaml"; sample "$cfg"; sha_before="$(sha256sum "$cfg")"
policy '{"extensions":{"todo":"false"}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "9 non-zero exit" test "$rc" -ne 0
check "9 file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 10. policy without an extensions object is refused
policy '{"todo":true}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "10 non-zero exit" test "$rc" -ne 0
check "10 file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 11. a non-mapping extension entry (goose would discard it) is replaced
cfg="$work/c11.yaml"; printf 'extensions:\n  todo: broken\n' > "$cfg"
policy '{"extensions":{"todo":true}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "11 exit 0" test "$rc" -eq 0
check "11 todo true" test "$(enabled_of "$cfg" todo)" = true

# 12. no temp files left beside the config
check "12 no temp leftovers" bash -c '! ls -A "$1" | grep -q "\.goose-config-enforce\."' _ "$work"

total=$((pass + fail))
if [ "$fail" -ne 0 ]; then
  echo "goose-config-enforce: $fail of $total assertions failed" >&2
  exit 1
fi
echo "goose-config-enforce: $pass passed"
