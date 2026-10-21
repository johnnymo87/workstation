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

# 6. missing file: left missing (creating it would skip goose's onboarding)
cfg="$work/new/dir/config.yaml"
policy '{"extensions":{"todo":true,"summon":false}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "6 exit 0" test "$rc" -eq 0
check "6 file not created" test ! -e "$cfg"
check "6 says it does not exist" grep -q 'does not exist' <<<"$out"

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

# 13. a symlinked config: the TARGET is rewritten, the link survives, and the
#     target keeps its own mode (not the link's 777)
mkdir -p "$work/real"; sample "$work/real/c13.yaml"; chmod 0600 "$work/real/c13.yaml"
ln -s "$work/real/c13.yaml" "$work/link13.yaml"
policy '{"extensions":{"todo":true}}'
bash "$enforce" "$work/link13.yaml" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "13 exit 0" test "$rc" -eq 0
check "13 link is still a symlink" test -L "$work/link13.yaml"
check "13 target updated" test "$(enabled_of "$work/real/c13.yaml" todo)" = true
check "13 target mode still 600" test "$(stat -c '%a' "$work/real/c13.yaml")" = 600

# 14. a dangling symlink counts as missing: exit 0, nothing created
ln -s "$work/nowhere/c14.yaml" "$work/link14.yaml"
bash "$enforce" "$work/link14.yaml" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "14 exit 0" test "$rc" -eq 0
check "14 target not created" test ! -e "$work/nowhere/c14.yaml"

# 15. a key with no entry is warned about (a typo looks exactly like this)
cfg="$work/c15.yaml"; sample "$cfg"
policy '{"extensions":{"extension_manager":false}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "15 exit 0" test "$rc" -eq 0
check "15 warns about the unknown key" grep -q "WARNING: no usable entry for 'extension_manager'" <<<"$out"
policy '{"extensions":{"todo":true}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"
check "15 no warning for an existing key" bash -c '! grep -q WARNING <<<"$1"' _ "$out"

# 16. a non-mapping extensions: is refused, untouched
cfg="$work/c16.yaml"; printf 'extensions: nope
' > "$cfg"; sha_before="$(sha256sum "$cfg")"
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "16 non-zero exit" test "$rc" -ne 0
check "16 file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 16b. extensions: false (a boolean, not a mapping) is refused too
cfg="$work/c16b.yaml"; printf 'extensions: false\n' > "$cfg"; sha_before="$(sha256sum "$cfg")"
policy '{"extensions":{"todo":true}}'
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "16b non-zero exit" test "$rc" -ne 0
check "16b file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 17. a multi-document file is refused, untouched
cfg="$work/c17.yaml"; printf 'a: 1\n---\nb: 2\n' > "$cfg"; sha_before="$(sha256sum "$cfg")"
bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
check "17 non-zero exit" test "$rc" -ne 0
check "17 file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 18. goose writes the file while the update is in flight: the attempt is
#     redone, so goose's write survives AND the policy is applied
cfg="$work/c18.yaml"; sample "$cfg"
shim="$work/shim"; mkdir -p "$shim"
real_yq="$(command -v yq)"
real_bash="$(command -v bash)"  # no /usr/bin/env in the nix sandbox
cat > "$shim/yq" <<SHIM
#!$real_bash
if [ "\$1" = "-i" ] && [ ! -e "$work/raced" ]; then
  touch "$work/raced"
  printf 'GOOSE_WROTE: yes\n' >> "$cfg"
fi
exec "$real_yq" "\$@"
SHIM
chmod +x "$shim/yq"
policy '{"extensions":{"todo":true}}'
out="$(PATH="$shim:$PATH" bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "18 exit 0" test "$rc" -eq 0
check "18 raced once" test -e "$work/raced"
check "18 retried" grep -q 'retrying' <<<"$out"
check "18 goose write kept" test "$(yq -r '.GOOSE_WROTE' "$cfg")" = yes
check "18 policy applied" test "$(enabled_of "$cfg" todo)" = true

# 19. a scalar entry (goose cannot read a flag from it and falls back to the
#     extension's default) is rewritten even when the scalar equals the policy
cfg="$work/c19.yaml"; printf 'extensions:\n  summon: false\n  todo: true\n' > "$cfg"
policy '{"extensions":{"summon":false,"todo":true}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "19 exit 0" test "$rc" -eq 0
check "19 summon is now a mapping" test "$(yq -r '.extensions.summon | tag' "$cfg")" = '!!map'
check "19 summon enabled false" test "$(enabled_of "$cfg" summon)" = false
check "19 todo is now a mapping" test "$(yq -r '.extensions.todo | tag' "$cfg")" = '!!map'
check "19 not reported unchanged" bash -c '! grep -q unchanged <<<"$1"' _ "$out"

# 20. policy keys are literal names: glob characters are refused
cfg="$work/c20.yaml"; sample "$cfg"; sha_before="$(sha256sum "$cfg")"
for key in 'a*' 'tod?' '*'; do
  policy "{\"extensions\":{\"$key\":false}}"
  bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
  check "20 '$key' refused" test "$rc" -ne 0
done
check "20 file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 21. settings written into a file lacking them; other keys untouched
cfg="$work/c21.yaml"; sample "$cfg"
policy '{"extensions":{"todo":true},"settings":{"GOOSE_SUBAGENT_ROLES_DIR":"/roles/path","GOOSE_SUBAGENT_DEFAULT_RECIPE":"/recipes/default.yaml"}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "21 exit 0" test "$rc" -eq 0
check "21 settings ROLES_DIR written" test "$(yq -r '.GOOSE_SUBAGENT_ROLES_DIR' "$cfg")" = '/roles/path'
check "21 settings DEFAULT_RECIPE written" test "$(yq -r '.GOOSE_SUBAGENT_DEFAULT_RECIPE' "$cfg")" = '/recipes/default.yaml'
check "21 todo updated" test "$(enabled_of "$cfg" todo)" = true
check "21 GOOSE_MODE untouched" test "$(yq -r '.GOOSE_MODE' "$cfg")" = smart_approve
check "21 providers untouched" test "$(yq -r '.providers.gcp_vertex_ai.model' "$cfg")" = claude-opus-5-5
check "21 plugins untouched" test "$(yq -r '.plugins."/tmp/x/.agents/plugins/p".enabled' "$cfg")" = true
check "21 reports settings in output" grep -q 'GOOSE_SUBAGENT_ROLES_DIR=/roles/path' <<<"$out"

# 22. already-matching settings → no rewrite (mtime unchanged)
before="$(stat -c '%i %Y %s' "$cfg")"; sha_before="$(sha256sum "$cfg")"
sleep 1
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "22 exit 0" test "$rc" -eq 0
check "22 reports unchanged" grep -q 'unchanged' <<<"$out"
check "22 same inode/mtime/size" test "$(stat -c '%i %Y %s' "$cfg")" = "$before"
check "22 same bytes" test "$(sha256sum "$cfg")" = "$sha_before"

# 23. different setting value → corrected, other keys untouched
policy '{"extensions":{"todo":true},"settings":{"GOOSE_SUBAGENT_ROLES_DIR":"/new/roles/path","GOOSE_SUBAGENT_DEFAULT_RECIPE":"/recipes/default.yaml"}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "23 exit 0" test "$rc" -eq 0
check "23 settings ROLES_DIR updated" test "$(yq -r '.GOOSE_SUBAGENT_ROLES_DIR' "$cfg")" = '/new/roles/path'
check "23 settings DEFAULT_RECIPE unchanged" test "$(yq -r '.GOOSE_SUBAGENT_DEFAULT_RECIPE' "$cfg")" = '/recipes/default.yaml'
check "23 GOOSE_MODE still untouched" test "$(yq -r '.GOOSE_MODE' "$cfg")" = smart_approve
check "23 reports updated setting" grep -q 'GOOSE_SUBAGENT_ROLES_DIR=/new/roles/path' <<<"$out"
check "23 does not report matching setting" bash -c '! grep -q "GOOSE_SUBAGENT_DEFAULT_RECIPE=" <<<"$1"' _ "$out"

# 24. invalid settings value or invalid key name: non-zero, file untouched
cfg="$work/c24.yaml"; sample "$cfg"; sha_before="$(sha256sum "$cfg")"
for bad_policy in \
  '{"extensions":{"todo":true},"settings":{"GOOSE_SUBAGENT_ROLES_DIR":123}}' \
  '{"extensions":{"todo":true},"settings":{"GOOSE_SUBAGENT_ROLES_DIR":true}}' \
  '{"extensions":{"todo":true},"settings":{"GOOSE_SUBAGENT_ROLES_DIR":["a"]}}' \
  '{"extensions":{"todo":true},"settings":{"lower_case":"/path"}}' \
  '{"extensions":{"todo":true},"settings":{"WITH-DASH":"/path"}}' \
  '{"extensions":{"todo":true},"settings":"not-an-object"}'; do
  policy "$bad_policy"
  bash "$enforce" "$cfg" "$work/policy.json" >/dev/null 2>&1; rc=$?
  check "24 bad policy refused ($bad_policy)" test "$rc" -ne 0
done
check "24 file untouched" test "$(sha256sum "$cfg")" = "$sha_before"

# 25. policy without settings behaves as before
cfg="$work/c25.yaml"; sample "$cfg"
policy '{"extensions":{"todo":true}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "25 exit 0" test "$rc" -eq 0
check "25 todo enabled" test "$(enabled_of "$cfg" todo)" = true
check "25 GOOSE_MODE kept" test "$(yq -r '.GOOSE_MODE' "$cfg")" = smart_approve

# 26. file with non-JSON-representable value (e.g. .nan) still has extensions and settings enforced
cfg="$work/c26.yaml"
cat > "$cfg" <<'EOF'
a: .nan
GOOSE_MODE: smart_approve
extensions:
  todo:
    enabled: false
EOF
policy '{"extensions":{"todo":true},"settings":{"GOOSE_SUBAGENT_ROLES_DIR":"/roles/path"}}'
out="$(bash "$enforce" "$cfg" "$work/policy.json" 2>&1)"; rc=$?
check "26 exit 0" test "$rc" -eq 0
check "26 todo updated" test "$(enabled_of "$cfg" todo)" = true
check "26 settings written" test "$(yq -r '.GOOSE_SUBAGENT_ROLES_DIR' "$cfg")" = '/roles/path'
check "26 nan preserved" test "$(yq -r '.a' "$cfg")" = '.nan'
check "26 GOOSE_MODE preserved" test "$(yq -r '.GOOSE_MODE' "$cfg")" = smart_approve

# 12. no temp files left beside the config
check "12 no temp leftovers" bash -c '! ls -A "$1" | grep -q "\.goose-config-enforce\."' _ "$work"

total=$((pass + fail))
if [ "$fail" -ne 0 ]; then
  echo "goose-config-enforce: $fail of $total assertions failed" >&2
  exit 1
fi
echo "goose-config-enforce: $pass passed"
