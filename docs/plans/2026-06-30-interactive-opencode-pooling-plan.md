# Interactive `opencode` Pooling — Implementation Plan

> **For Claude:** Execute task-by-task. The user chose **subagent-driven-development**
> (dispatch `implementer` per task, `code-reviewer`/`spec-reviewer` between tasks).
> Design (v2, approved): `docs/plans/2026-06-30-interactive-opencode-pooling-design.md`.
> Adversarial review: `docs/plans/2026-06-30-interactive-opencode-pooling-review-opus48.md`.
> Bead: `workstation-jiae`. Worktree: `~/projects/ws-iwpj-phase2`, branch
> `iwpj-phase2-interactive`. Host: cloudbox.

**Goal:** Make plain/interactive `opencode` join the 4-serve pool by intercepting
the default-TUI / `-s` resume invocation, creating+placing a session via pigeon,
and `exec`ing `opencode attach <owner> --session <sid> --dir <server-dir>` — so
interactive TUIs distribute like Phase-1 launches/attaches do. Degrade to
self-host on any failure (never worse than today).

**Architecture:** A tested `pkgs/oc-pool-attach` shell placer (pure helpers
`classify_oc_invocation` + `parse_serve_url`, then the create/place/attach flow,
exec'ing the real opencode by store path) + a gated shadow `opencode()` bash
function in `users/dev/home.base.nix` (interactive shells, `K ≥ 2` hosts only)
that delegates to it. No `opencode-patched` change (attach is already pool-aware
and self-healing).

**Tech Stack:** Nix (`writeShellApplication`, home-manager), bash, `curl`+`jq`,
pigeon `POST /place` / `GET /route` / `GET|POST /session`.

**Key constraints (from the v2 design — do not regress):**
- M1: `--dir` = the session's **server-stored `.directory`** (read back from
  `POST /session` for NEW, `GET /session/<sid>` for RESUME), never `$PWD`.
- M2: NEW pre-checks pigeon reachable **before** `POST /session`; RESUME
  self-hosts on any `/place` non-2xx (409/503/timeout). Never attach `:4096` as a
  non-owner for RESUME.
- M3: classifier scans the **whole argv**; RESUME→NEW misclassification is the
  dangerous case (silently drops a resume). Validate sid `^ses_[A-Za-z0-9_-]+$`.
- M4: gate pooling on `K ≥ 2` (`serve-pool.nix forHost.<host>.k`); crostini K=1
  stays self-host.
- M5: non-TTY stdin (`echo … | opencode`) → PASSTHROUGH (attach drops stdin).
- MINOR-2: snapshot pristine argv (`original_args=("$@")`) for every fallback exec.

---

## Task 1: `classify_oc_invocation` pure helper (test-first)

**Files:**
- Create: `pkgs/oc-pool-attach/test.sh`
- Create: `pkgs/oc-pool-attach/default.nix`

**Step 1 — Write the failing test.** Create `pkgs/oc-pool-attach/test.sh` with the
`assert_eq` infra (copy from `pkgs/opencode-launch/test.sh:58-66`) and a **mirror**
of `classify_oc_invocation` (see Step 3 for the canonical body — the mirror must
be byte-identical to the one in `default.nix`, kept in lockstep by the source-grep
guard in Task 2). Output contract: always three tab-separated fields
`VERB\tSID\tPROJECT` (SID/PROJECT empty when N/A), VERB ∈ `NEW|RESUME|PASSTHROUGH`.

Cases (use `$'…\t…'` literals):
```bash
T() { assert_eq "$1" "$(classify_oc_invocation "${@:2}")" "classify: ${*:2}"; }
T $'NEW\t\t'                 # bare
T $'NEW\t\t/home/dev/x'      ./… ; actually: opencode <project>  (abs not required here; classifier echoes raw)
T $'NEW\t\tmyproj'          myproj
T $'RESUME\tses_abc\t'       -s ses_abc
T $'RESUME\tses_abc\t'       --session ses_abc
T $'RESUME\tses_abc\t'       --session=ses_abc
T $'RESUME\tses_abc\t'       -sses_abc
T $'RESUME\tses_abc\tproj'   proj -s ses_abc        # trailing -s (MAJOR-3)
T $'RESUME\tses_abc\tproj'   -s ses_abc proj
# PASSTHROUGH: subcommands (exact-token), boundaries, incompatible flags, bad sids
for sc in completion acp mcp attach run debug providers auth agent upgrade uninstall serve web models stats export import github pr session plugin plug db; do
  T $'PASSTHROUGH\t\t' "$sc"
done
T $'NEW\t\t./serve'          ./serve     # dir literally named serve != exact 'serve'
T $'NEW\t\trunfoo'           runfoo
T $'PASSTHROUGH\t\t'         -- proj      # -- terminator: be conservative
T $'PASSTHROUGH\t\t'         --model X
T $'PASSTHROUGH\t\t'         -m X
T $'PASSTHROUGH\t\t'         --agent build
T $'PASSTHROUGH\t\t'         --prompt hi
T $'PASSTHROUGH\t\t'         --port 5000
T $'PASSTHROUGH\t\t'         --hostname 0.0.0.0
T $'PASSTHROUGH\t\t'         -c
T $'PASSTHROUGH\t\t'         --continue
T $'PASSTHROUGH\t\t'         --pure
T $'PASSTHROUGH\t\t'         -h
T $'PASSTHROUGH\t\t'         -v
T $'PASSTHROUGH\t\t'         -s ses_abc --model Y   # RESUME token + incompatible flag
T $'PASSTHROUGH\t\t'         -s                     # no value
T $'PASSTHROUGH\t\t'         -s bad!sid             # regex fail
T $'PASSTHROUGH\t\t'         proj1 proj2            # >1 positional
```
(For the `--` terminator: simplest safe choice is PASSTHROUGH; adjust the test to
match the implementation you settle on, but document it.)

**Step 2 — Run, expect FAIL.** `bash pkgs/oc-pool-attach/test.sh` → fails (no
`default.nix` yet / mirror mismatch). NOTE: `test.sh` will source-grep
`default.nix` in Task 2; for Task 1 just exercise the mirrored function.

**Step 3 — Implement `classify_oc_invocation` in `pkgs/oc-pool-attach/default.nix`.**
Create the `writeShellApplication` skeleton (`runtimeInputs = [ pkgs.curl pkgs.jq
pkgs.gnugrep pkgs.coreutils ];`, arg `{ pkgs, opencode, k }:`). Canonical body
(mirror this exactly into test.sh):
```bash
classify_oc_invocation() {
  local subcmds="completion acp mcp attach run debug providers auth agent upgrade uninstall serve web models stats export import github pr session plugin plug db"
  local sid="" project="" have_session=0 positionals=0 first_pos_checked=0 a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --) printf 'PASSTHROUGH\t\t\n'; return 0 ;;   # conservative
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
```
(Remember writeShellApplication is a Nix string: shell `${var}` must be written
`''${var}`; Nix `${opencode}` stays bare.)

**Step 4 — Run, expect PASS** (classify cases). `bash pkgs/oc-pool-attach/test.sh`.

**Step 5 — Commit.** `git add pkgs/oc-pool-attach/ && git commit -m "feat(oc-pool-attach): classify_oc_invocation pure helper (workstation-jiae)"`

---

## Task 2: `parse_serve_url` + flow + source-grep guards

**Files:** Modify `pkgs/oc-pool-attach/{default.nix,test.sh}`.

**Step 1 — Add failing tests.** In `test.sh`: (a) mirror `parse_serve_url` from
`pkgs/opencode-launch/test.sh:17-25` and copy its parse_serve_url assertions
(`:76-100`); (b) add a **source-grep guard** block (model on
`opencode-launch/test.sh:148-217`) asserting `default.nix` contains:
`parse_serve_url()`, `classify_oc_invocation()`, `PIGEON_DAEMON_URL`,
`POST "$PIGEON_DAEMON_URL/place"` (escaped), `GET`-style `"$OPENCODE_URL/session/`,
`POST "$OPENCODE_URL/session"`, `attach` with `--session` and `--dir`, the stdin
guard `[ -t 0 ]`, a `POOL_K` / `k`-gate, a `pigeon_reachable`, and
`original_args`. Run → FAIL (flow absent).

**Step 2 — Implement the flow in `default.nix`** (after the helpers). Skeleton:
```bash
OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
PIGEON_DAEMON_URL="''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"
POOL_K="${toString k}"
REAL_OPENCODE="${opencode}/bin/opencode"
original_args=("$@")
selfhost() { exec "$REAL_OPENCODE" "''${original_args[@]+"''${original_args[@]}"}"; }

# M4 gate + M5 stdin guard
[ "$POOL_K" -ge 2 ] 2>/dev/null || selfhost
[ -t 0 ] || selfhost

cls="$(classify_oc_invocation "$@")"
IFS=$'\t' read -r verb sid project <<<"$cls"
[ "$verb" = "PASSTHROUGH" ] && selfhost

pigeon_reachable() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
    "$PIGEON_DAEMON_URL/route?session_id=ses_poolprobe" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}
place_auth=(); [ -n "''${PIGEON_DAEMON_AUTH_TOKEN:-}" ] && place_auth=(-H "Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN")

if [ "$verb" = "NEW" ]; then
  pigeon_reachable || selfhost                                  # M2: before create
  curl -sf --max-time 5 "$OPENCODE_URL/global/health" >/dev/null 2>&1 || selfhost
  dir_in="''${project:-$PWD}"; dir_in="''${dir_in/#\~/$HOME}"
  [ -d "$dir_in" ] || selfhost                                  # non-dir project -> let opencode error
  dir_in="$(cd "$dir_in" && pwd)"
  resp="$(curl -sf -X POST "$OPENCODE_URL/session" -H "x-opencode-directory: $dir_in" 2>/dev/null || true)"
  sid="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
  [ -n "$sid" ] || selfhost
  dir="$(printf '%s' "$resp" | jq -r '.directory // empty' 2>/dev/null || true)"  # M1
  [ -n "$dir" ] || dir="$dir_in"
  place="$(curl -sf --connect-timeout 2 --max-time 3 -X POST "$PIGEON_DAEMON_URL/place" \
    -H "Content-Type: application/json" "''${place_auth[@]+"''${place_auth[@]}"}" \
    -d "{\"session_id\":\"$sid\"}" 2>/dev/null || true)"
  serve_url="$(parse_serve_url "$place" "$OPENCODE_URL")"
  exec "$REAL_OPENCODE" attach "$serve_url" --session "$sid" --dir "$dir"
fi

if [ "$verb" = "RESUME" ]; then
  body="$(curl -s -o - -w $'\n%{http_code}' --connect-timeout 2 --max-time 3 "$OPENCODE_URL/session/$sid" 2>/dev/null || true)"
  code="''${body##*$'\n'}"; body="''${body%$'\n'*}"
  [ "$code" = "200" ] || selfhost                               # absent/unreachable -> self-host
  dir="$(printf '%s' "$body" | jq -r '.directory // empty' 2>/dev/null || true)"  # M1
  [ -n "$dir" ] || selfhost
  place="$(curl -s -o - -w $'\n%{http_code}' --connect-timeout 2 --max-time 3 -X POST "$PIGEON_DAEMON_URL/place" \
    -H "Content-Type: application/json" "''${place_auth[@]+"''${place_auth[@]}"}" \
    -d "{\"session_id\":\"$sid\"}" 2>/dev/null || true)"
  pcode="''${place##*$'\n'}"; pbody="''${place%$'\n'*}"
  case "$pcode" in 2??) : ;; *) selfhost ;; esac               # M2: 409/503/timeout -> self-host
  serve_url="$(parse_serve_url "$pbody" "$OPENCODE_URL")"
  exec "$REAL_OPENCODE" attach "$serve_url" --session "$sid" --dir "$dir"
fi

selfhost   # unreachable
```
(Refine the http-code capture to your taste; the contract is what matters. Keep
`parse_serve_url` identical to opencode-launch's.)

**Step 3 — Run, expect PASS** (all helper + source-grep tests).
`bash pkgs/oc-pool-attach/test.sh`.

**Step 4 — Spec-review** (dispatch `spec-reviewer`): verify the flow matches the
v2 design's M1–M5 + fallback table exactly; no extra behavior.

**Step 5 — Commit.** `git commit -am "feat(oc-pool-attach): create/place/attach flow + guards (workstation-jiae)"`

---

## Task 3: Wire into home-manager (placer pkg + gated shadow function)

**Files:** Modify `users/dev/home.base.nix`.

**Step 1 — Resolve K + the placer pkg.** In the top-level `let` (near the
`opencode` binding ~line 54), add:
```nix
servePool = import ./serve-pool.nix;
servePoolK =
  if isCloudbox then servePool.forHost.cloudbox.k
  else if isCrostini then servePool.forHost.crostini.k
  else if isDarwin then servePool.forHost.darwin.k
  else servePool.forHost.devbox.k;
oc-pool-attach = pkgs.callPackage ../../pkgs/oc-pool-attach { inherit opencode; k = servePoolK; };
```

**Step 2 — Add to `home.packages`.** Next to `localPkgs.opencode-launch`
(line ~401), add `oc-pool-attach` (only meaningful where the function exists, but
harmless elsewhere; or gate with `lib.optionals (servePoolK >= 2) [ oc-pool-attach ]`).

**Step 3 — Add the gated shadow function** to `programs.bash.initExtra` (next to
`dd()` ~line 1283):
```nix
'' + lib.optionalString (servePoolK >= 2) ''
  # Pool interactive opencode (workstation-jiae). Interactive-only (this
  # initExtra runs after the ~/.bashrc interactive guard, like dd()). Delegates
  # to the oc-pool-attach placer, which pools a fresh TUI / -s resume onto a pool
  # serve via pigeon and self-hosts (today's behavior) on any failure. `command`
  # avoids re-entering this function; the placer execs the real binary by store
  # path. nvim jobstart / systemd serves / scripts never see this (non-interactive).
  opencode() { command oc-pool-attach "$@"; }
'' + ''
```
(Splice carefully into the existing `initExtra = '' … '';` string; keep it valid.)

**Step 4 — Build (no switch).** Run:
`nix run home-manager -- build --flake .#cloudbox`
Expected: builds clean (the placer compiles; `shellcheck` in `writeShellApplication`
passes). Fix any shellcheck/Nix-escaping errors.

**Step 5 — Commit.** `git commit -am "feat(home): gated shadow opencode() + oc-pool-attach wiring (workstation-jiae)"`

---

## Task 4: Deploy + validate on cloudbox (gated on user authority — already given)

**Step 1 — Switch.** `nix run home-manager -- switch --flake .#cloudbox`
(clients-only; NO `opencode serve` restart needed).

**Step 2 — Validate (new interactive session distributes).** In a NON-`:4096`
test: open a fresh shell, `cd ~/projects/<repo>`, run `opencode`; from another
shell confirm a `session_assignment` row exists for the new sid and its owner is
not always `:4096` (check `GET /route` / pigeon DB), and the TUI renders.
**MAJOR-1 check:** `opencode -s <existing-sid>` from a DIFFERENT cwd than the
session's dir → TUI renders turns (no freeze). **MAJOR-5 check:**
`echo "hello" | opencode` → self-hosts and shows the prompt (does NOT silently
drop it). **MAJOR-2 check:** `sudo systemctl stop pigeon-daemon` → `opencode`
self-hosts with no error → restart pigeon.

**Step 3 — Update bead + land the plane.** `bd update workstation-jiae` (status,
validation notes), then per AGENTS.md: `git pull --rebase`, `git push`,
`git status` clean. (Push is now authorized.)

---

## Notes / gotchas

- `writeShellApplication` runs `shellcheck`; the `''${arr[@]+"''${arr[@]}"}`
  empty-array guard under `set -u` is required (see opencode-launch).
- The placer is wired via `home.base.nix` `callPackage` (not `flake.nix`
  localPkgs) because the real `opencode` binary is defined in `home.base.nix`.
  Consequence: `nix build .#oc-pool-attach` won't exist; that's fine (not
  nix-update-tracked). The unit `test.sh` runs standalone via `bash test.sh`.
- Cross-host: function gated `K ≥ 2` → cloudbox(4)/devbox(2)/darwin(2) get it;
  crostini(1) stays self-host. The placer also self-hosts if `POOL_K < 2`.
- Do NOT touch `~/projects/workstation` (other sessions). Commit to
  `iwpj-phase2-interactive` only.
```
