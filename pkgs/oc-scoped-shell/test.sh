#!/usr/bin/env bash
set -euo pipefail

fail=0
pass=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

check() { # check <desc> <expected-substring> <haystack>
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else
    bad "$1"
    printf '       expected to find: %s\n' "$2"
    printf '       in: %s\n' "$3"
  fi
}

refute() { # refute <desc> <forbidden-substring> <haystack>
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else
    bad "$1"
    printf '       expected NOT to find: %s\n' "$2"
    printf '       in: %s\n' "$3"
  fi
}

# Determine wrapper bin
wrapper_bin="${WRAPPER_BIN:-}"
if [ -z "$wrapper_bin" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  wrapper_bin="$script_dir/../../result/bin/oc-scoped-shell"
fi

if [ ! -f "$wrapper_bin" ]; then
  echo "FAIL: WRAPPER_BIN not found at $wrapper_bin" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Static checks: store path invariants
# ---------------------------------------------------------------------------
echo "== static: store path invariants =="

real_line=$(grep -m1 '^REAL_BASH=' "$wrapper_bin" || true)
sdrun_line=$(grep -m1 '^SYSTEMD_RUN=' "$wrapper_bin" || true)

if [[ "$real_line" =~ ^REAL_BASH=\"?/nix/store/ ]]; then
  ok "REAL_BASH is an absolute /nix/store path"
else
  bad "REAL_BASH must be an absolute /nix/store path, got: ${real_line:-<missing>}"
fi

if [[ "$sdrun_line" =~ ^SYSTEMD_RUN=\"?/nix/store/ ]]; then
  ok "SYSTEMD_RUN is an absolute /nix/store path"
else
  bad "SYSTEMD_RUN must be an absolute /nix/store path, got: ${sdrun_line:-<missing>}"
fi

# ---------------------------------------------------------------------------
# 2. Harness setup
# ---------------------------------------------------------------------------
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

bash_bin="$(command -v bash)"
log_file="$tmp_dir/stub.log"

stub_sdrun="$tmp_dir/stub-systemd-run"
cat << EOF > "$stub_sdrun"
#!$bash_bin
set -euo pipefail
echo "SDRUN: \$*" >> "$log_file"

for a in "\$@"; do
  if [ "\$a" = "true" ]; then
    exit "\${STUB_PROBE_RC:-0}"
  fi
done

cmd=()
seen=0
for a in "\$@"; do
  if [ "\$seen" -eq 1 ]; then
    cmd+=("\$a")
  elif [ "\$a" = "--" ]; then
    seen=1
  fi
done

if [ "\${#cmd[@]}" -gt 0 ]; then
  exec "\${cmd[@]}"
fi
exit 0
EOF
chmod +x "$stub_sdrun"

# Create harness wrapper by substituting store paths with stubs
test_wrapper="$tmp_dir/test-wrapper"
sed -e "s|^SYSTEMD_RUN=.*|SYSTEMD_RUN=\"$stub_sdrun\"|" \
    -e "s|^REAL_BASH=.*|REAL_BASH=\"$bash_bin\"|" \
    "$wrapper_bin" > "$test_wrapper"
chmod +x "$test_wrapper"

# ---------------------------------------------------------------------------
# 3. Behavioural tests
# ---------------------------------------------------------------------------
echo "== behavioural tests =="

# A. Probe success path: argv passthrough, systemd flags, unit names
> "$log_file"
export STUB_PROBE_RC=0
out="$("$test_wrapper" -c 'FOO=hello; BAR=world; echo "both=${FOO} and ${BAR} and '\''single'\''"')"

check "argv passthrough preserves variables and quotes" "both=hello and world and 'single'" "$out"

log_content="$(cat "$log_file")"
check "systemd-run probe unit starts with oc-scoped-shell-probe-" "SDRUN: --user --scope --collect --quiet --unit=oc-scoped-shell-probe-" "$log_content"
check "systemd-run flags: --expand-environment=no" "--expand-environment=no" "$log_content"
check "systemd-run flags: -p MemoryMax=10G" "-p MemoryMax=10G" "$log_content"
check "systemd-run flags: -p MemorySwapMax=2G" "-p MemorySwapMax=2G" "$log_content"
check "systemd-run flags: -p OOMPolicy=continue" "-p OOMPolicy=continue" "$log_content"
check "systemd-run flags: --slice=oc-agent" "--slice=oc-agent" "$log_content"
check "systemd-run scope unit starts with oc-agent-" "--unit=oc-agent-" "$log_content"
refute "emitted unit name does NOT match run-p*" "run-p" "$log_content"

# B. Single execution guarantee on non-zero exit (probe success)
count_file="$tmp_dir/exec_count.txt"
rc=0
"$test_wrapper" -c 'echo line >> "'"$count_file"'"; exit 42' || rc=$?
if [ "$rc" -eq 42 ]; then
  ok "non-zero exit code 42 propagates correctly"
else
  bad "non-zero exit code expected 42, got $rc"
fi
lines="$(wc -l < "$count_file")"
if [ "$lines" -eq 1 ]; then
  ok "payload runs exactly once when exiting non-zero"
else
  bad "payload ran $lines times instead of exactly once"
fi

# C. Exit code propagation
rc=0
"$test_wrapper" -c 'exit 0' || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "exit code 0 propagates"
else
  bad "exit code expected 0, got $rc"
fi

rc=0
"$test_wrapper" -c 'exit 127' || rc=$?
if [ "$rc" -eq 127 ]; then
  ok "exit code 127 propagates"
else
  bad "exit code expected 127, got $rc"
fi

# D. Degrade path (probe failure)
export STUB_PROBE_RC=1
count_file_degrade="$tmp_dir/exec_count_degrade.txt"
err_log="$tmp_dir/stderr.log"

rc=0
"$test_wrapper" -c 'echo degrade >> "'"$count_file_degrade"'"; exit 13' 2>"$err_log" || rc=$?

if [ "$rc" -eq 13 ]; then
  ok "degrade path propagates exit code 13"
else
  bad "degrade path exit code expected 13, got $rc"
fi

lines="$(wc -l < "$count_file_degrade")"
if [ "$lines" -eq 1 ]; then
  ok "degrade path runs payload exactly once"
else
  bad "degrade path payload ran $lines times instead of exactly once"
fi

err_content="$(cat "$err_log")"
check "degrade path emits warning on stderr" "oc-scoped-shell: WARNING:" "$err_content"

if [ "$fail" -ne 0 ]; then
  echo "oc-scoped-shell tests FAILED" >&2
  exit 1
fi

echo "ALL PASS (oc-scoped-shell wrapper tests, $pass assertions)"
