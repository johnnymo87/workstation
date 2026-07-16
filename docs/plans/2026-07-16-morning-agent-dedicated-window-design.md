# Morning agent: dedicated, non-headless TUI window

## Context

`reset-workspace` (the nightly 3 AM `nightly-restart-background.service` on
devbox + cloudbox) launches a "morning" recommendation/coordinator opencode
session via `opencode-launch '~' "$RECOMMENDATION_PROMPT"`
(`pkgs/reset-workspace/default.nix:609`). The agent reads the manifest, sends
a Telegram message describing the captured sessions, reopens the ones the user
picks, and stays on as swarm coordinator.

The user experiences this agent as "headless" (reachable only via Telegram).
Investigation of `/tmp/oc-auto-attach.log` on devbox shows the real behavior is
worse than headless — it is **nondeterministic and sometimes destructive**,
all because the agent launches with `cwd=~` (`/home/dev`):

- `opencode-launch` unconditionally fires
  `oc-auto-attach --tmux-session main <sid>` (`pkgs/opencode-launch/default.nix:431-438`).
- `oc-auto-attach` derives the tmux window from the session directory
  (`pkgs/oc-auto-attach/default.nix:366-372`). For `cwd=/home/dev` the regex
  `^${HOME}/projects/…` fails, so `project_key=/home/dev`, `window_name=dev`.
- Outcomes observed in the log:
  - **No `/home/dev` pane** → creates a fresh window literally named `dev`
    (log:74) — unrecognizable as the morning agent.
  - **A `/home/dev` bash pane exists** → `classify_pane` → `SEND_NVIMS` →
    **hijacks the user's home shell pane** (log:82-84).
  - **That pane runs something non-shell** → `SKIP` → **truly headless**.

So the root cause is: launching in `~` gives `oc-auto-attach` no clean,
dedicated place to land, so it either mislabels, clobbers, or gives up.

## Goal

Give the morning agent a **dedicated, clearly-named TUI window** (e.g.
`morning`) in the user's `main` tmux session that:

- is created fresh each reset,
- is unambiguously recognizable,
- **never** hijacks an existing pane (esp. the home shell),
- keeps the existing Telegram flow intact (TUI-primary, Telegram fallback).

## Non-goals

- Removing or changing the Telegram messaging / swarm-coordinator behavior.
- Changing `oc-auto-attach` or `opencode-launch` (see rejected Approach B).

## In scope (added after adversarial review)

- **Self-skip the previous morning agent.** The dedicated `~/morning` dir is a
  perfect self-identification marker, and the agent's own attach client is
  captured by the next reset's snapshot (this already happens today at
  `cwd=/home/dev`; after this change it happens deterministically every night on
  both hosts). Add one line to the recommendation prompt telling the agent to
  skip any manifest sid whose directory is `$HOME/morning`, and to keep scratch
  files in `/tmp` (not `~/morning`) so the marker dir stays uninhabited — an
  inhabited `~/morning` shell pane is the *only* scenario that could re-enable a
  `SEND_NVIMS` hijack.

## Approach (chosen): marker directory

Launch the agent in a **dedicated directory** (`$HOME/morning`) instead of `~`.
This leverages `oc-auto-attach`'s existing `basename`-derived window naming and
its cwd-based pane matching, with **zero changes to `oc-auto-attach` or
`opencode-launch`**:

- `session_dir=/home/dev/morning` → `project_key=/home/dev/morning`,
  `window_name=morning`.
- Step-3 pane scan finds no pane whose `pane_current_path` is `/home/dev/morning`
  (nobody works there), so `oc-auto-attach` takes the **create-fresh-window**
  branch (`pkgs/oc-auto-attach/default.nix:413-425`) → a new `morning` window.
- The home shell pane at `/home/dev` is a **parent** of `/home/dev/morning`,
  which does **not** satisfy either the exact (`==`) or descendant (`/*`) match
  in `oc-auto-attach.default.nix:387-398` — so it can never be hijacked.

### Changes to `pkgs/reset-workspace/default.nix`

All within the Step 6 launch block (`:566-612`):

1. Define `MORNING_DIR="$HOME/morning"` and `mkdir -p "$MORNING_DIR"` before the
   launch (the dir must exist so both `opencode-launch`'s session-create and
   `oc-auto-attach`'s `tmux new-window -c "$MORNING_DIR"` land there).
2. Change the launch from `opencode-launch '~' "$RECOMMENDATION_PROMPT"` to
   `opencode-launch "$MORNING_DIR" "$RECOMMENDATION_PROMPT"` (`:609`).
3. Update the log line `launching recommendation session in ~ ...` (`:577`) to
   reflect `$MORNING_DIR`.
4. Soften the prompt's headless justification (`:594`). It currently reads
   "you are a headless session not attached to tmux" to justify
   `--tmux-session main`. The agent now has a TUI tab, but its **bash-tool
   invocations still run inside the opencode-serve process, not inside the tmux
   pane** (`$TMUX` is unset there), so `--tmux-session main` remains mandatory.
   Reword the rationale to "your bash tools do not run inside tmux, so without
   `--tmux-session main` the reopened tab lands in whatever session tmux
   considers current" — keep the flag, fix the reasoning.

### Doc / skill updates (wording only)

- `.opencode/skills/resetting-workspace/SKILL.md` — the flow description
  (`:17`, `:30-33`, `:110`) says the agent is headless; update to "lands in a
  dedicated `morning` window in `main`; still messages you over Telegram."
- `assets/opencode/skills/understanding-workspace-reset/SKILL.md` — the
  frontmatter and body (`:3`, `:27-28`) describe it as headless-from-`~`;
  update to the dedicated-window model.
- `assets/opencode/AGENTS.md:38` — "headless morning recommendation agent"
  wording.

## Data flow (unchanged except cwd)

`reset-workspace` → `opencode-launch "$HOME/morning" "$PROMPT"` → session
created with `x-opencode-directory=/home/dev/morning` → `opencode-launch` fires
`oc-auto-attach --tmux-session main <sid>` → `oc-auto-attach` creates a fresh
`morning` window running `nvims`, opens the `opencode attach` tab there →
agent sends Telegram message → user replies → agent reopens chosen sids via
`oc-auto-attach --tmux-session main <sid>` (unchanged).

## Error handling / edge cases

| Case | Behavior |
|------|----------|
| `$HOME/morning` mkdir fails (disk full) | `mkdir -p` failure is non-fatal; log a warning and still attempt the launch. tmux `new-window -c <missing>` is verified to silently fall back (rc=0); the opencode-serve behavior with a missing `x-opencode-directory` is **unverified** but only reachable in this disk-full state, so best-effort is acceptable. |
| Previous reset left a live `morning` nvim | reset SIGKILLs all nvim first (`:475`), so the stale `morning` pane is gone before launch; even if one survived, `oc-auto-attach` would `REUSE` it — still a clean `morning` window. |
| Cloudbox (headless host) | The attach path **does** run: `oc-auto-attach` + `nvims` ship via `home.base.nix:474-478` on all hosts, and the cloudbox nightly unit runs as `dev` with `~/.nix-profile/bin` on PATH and drives the user's tmux (`hosts/cloudbox/configuration.nix`). So a `morning` window is created in `main` (creating that tmux session detached if absent). This is not a regression — the same happens today with a `dev` window — and is an improvement. Only a host lacking the home.base.nix packages (none of the four) would no-op the attach. |
| First morning after deploy (transition) | Tonight's manifest still holds legacy `cwd=/home/dev` morning-agent sids. Reopening them descendant-matches the new `morning` pane (`/home/dev/morning` **is** a descendant of `/home/dev`, `oc-auto-attach:393`) and opens their tab in the `morning` window. Cosmetic (wrong window, not destructive), one-time. |
| A pane genuinely sits at `/home/dev/morning` | would be reused/hijacked — but nobody works in this marker dir (the prompt keeps scratch in `/tmp`), so this is only reachable by the agent's own prior nvim (already covered above). |

## Testing

- `nix build .#reset-workspace --no-link` — runs `writeShellApplication`'s
  shellcheck over the modified script.
- Optional `want_grep` assertions in `pkgs/reset-workspace/test.sh`: assert the
  launch targets `"$MORNING_DIR"` and that `MORNING_DIR` is `mkdir -p`'d before
  the launch.
- **Non-destructive live check** (do NOT run a full `reset-workspace --yes`
  mid-session — it kills all nvims + restarts the serve pool): manually run
  `opencode-launch "$HOME/morning" "say hi and stop"` on devbox and confirm
  (a) a new `morning` window appears in `main`, (b) no existing pane was
  hijacked, (c) `/tmp/oc-auto-attach.log` shows
  `project_key=/home/dev/morning window_name=morning` + `created pane … (window morning)`.
  Then delete the throwaway session.
- Full end-to-end (`reset-workspace --yes`) deferred to a deliberate run when
  the user is ready, or the natural 3 AM trigger.

## Rejected alternative: Approach B (`--window-name` flag)

Add `--window-name <name>` to `oc-auto-attach` (force a fresh named window,
skip pane matching), forward it through `opencode-launch`, and have
`reset-workspace` pass `--window-name morning`. More explicit and gives a hard
"never reuse" guarantee with no marker dir, but threads a new flag through
three packages plus their `test.sh` files. Rejected for scope: Approach A
achieves the same user-visible outcome with a ~5-line change and no marker-dir
downside in practice (nobody works in `~/morning`).
