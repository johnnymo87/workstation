---
name: predicting-switch-restarts
description: Predicts which systemd units a nixos-rebuild switch or home-manager switch would stop, start, restart or reload on devbox or cloudbox, and what that does to live agent turns (goose, honk game characters, opencode) and to their model path (teamclaude, cfp-shaper, claude-failover-proxy). Use before switching while agent sessions or a live window are running, when asked whether a switch restarts goose, honkd or the opencode serves, when choosing a moment to deploy, or when a turn failed around the time of a deploy.
---

# Predicting switch restarts

## Quick start

From a checkout of exactly what you are about to deploy (see "Switching safely" for which):

```bash
.agents/skills/predicting-switch-restarts/switch-impact.sh .
```

It builds both generations, without switching, and prints:

- **SYSTEM**: `switch-to-configuration dry-activate` (needs `sudo -n`) and the closure delta.
- **HOME**: the new generation's own `sd-switch --dry-run` against the current
  generation, plus each changed unit file and its `X-SwitchMethod`.
- `>> WATCHED units named above:` lists any unit from the table below. If one is
  named, read its row before you switch.

The result is a diff against what is running now. If anyone else switches
afterwards, run it again. To check the script against a past switch you have a
journal for, set `SWITCH_IMPACT_OLD_HM=<old generation path>`. Replaying devbox
HM generation 761→762 printed `Stopping units: teamclaude.service`, which matches
the journal for 2026-11-28 15:01:03Z.

## What a switch does to a unit

**System switch** (`switch-to-configuration`):

| Unit setting | Unit definition changed | Unit unchanged |
|---|---|---|
| default | stopped **before** activation, started **after**: down for the whole activation (`stopIfChanged = true`) | left alone |
| `stopIfChanged = false` | restarted after activation (shorter gap) | left alone |
| `restartIfChanged = false` | left running the OLD code (`would NOT restart`) | left alone |
| `reloadIfChanged` / `reloadTriggers` | reloaded | left alone |

Two more effects:

- The daemon-reload re-applies cgroup limits (MemoryMax and the like) to running
  units, including the `restartIfChanged = false` ones.
- Any enabled unit that is not running gets started. That undoes a hand-stop, and
  dry-activate does not predict it (see the `rebuilding` skill).

**Home switch** (sd-switch): a changed user unit is stopped and started unless it
has `X-SwitchMethod = "keep-old"`. A removed unit is stopped. Inactive wanted
units are started; `ensure-projects` starts on every switch.

**Neither switch restarts anything just because a file it reads changed.** Agent
definitions, skills and configs are re-read whenever their reader next reads
them. For a long-running serve, that may be its next restart.

## devbox

Nothing runs `nixos-rebuild` on devbox automatically. `pull-workstation.timer`
runs `home-manager switch --flake .#dev` **unattended, about every 4 hours**. So
an HM change to a unit without keep-old lands within hours, at a moment nobody
chose.

| Unit | Kind | When a switch changes it | Why |
|---|---|---|---|
| `goose-serve` | system | **never restarted** | `restartIfChanged = false`, `hosts/devbox/configuration.nix`. Picks up changes at the nightly reset (03:00 ET) or a goose cutover. |
| `honkd` | user | **never restarted** | keep-old, `users/dev/home.devbox.nix` |
| `opencode-serve@*`, `opencode-frontdoor` | user | **never restarted** | keep-old. They keep running the old opencode until restarted. |
| goose-agent slice | user | never stopped | keep-old, `users/dev/goose-agent.nix`. Stopping it would kill every goose tool command. |
| `cfp-shaper` | system | **stopped for the whole activation**, then started | default. goose's Anthropic route is goose → `:3457` cfp-shaper → `:3456` teamclaude. |
| `teamclaude` | user | **stopped and started** (about 1 s) | no keep-old. Both goose (through cfp-shaper) and opencode reach Anthropic through it. |
| `pigeon-daemon` | system | restarted | default |
| `codex-lb`, `oc-tags-serve`, `tmux-main`, `tec-codex-bot*` | user | restarted | no keep-old |

goose-serve's dependency on cfp-shaper is `wants` + `after`, not `requires` or
`bindsTo`, so stopping cfp-shaper does not stop goose. Both of the switches leave
goose itself running. What they can cut is goose's **model requests**.

## cloudbox

These are `restartIfChanged = false` system units: `goose-serve`,
`opencode-serve@`, `opencode-frontdoor` and `aigateway`. `honkd` is a keep-old
user unit. `teamclaude` and `claude-failover-proxy` are system units with no
such setting, so they **restart** when changed. Every agent's Claude traffic goes
through cfp. For what the no-restart units need after a switch (drift, explicit
restarts), see the `rebuilding` skill's front-door and serve-pool runbook. For
the actual list, run the script.

## macOS

Not covered by the script. `home-switch` re-bootstraps every launchd agent whose
plist changed, and that restarts it, the opencode serve included. To check before
a switch, build the generation and diff
`<new generation>/home-files/Library/LaunchAgents` against `~/Library/LaunchAgents`.

## What a cut does to a goose turn

This is from the goose v1.60.2 source (`aaif-goose/goose`):

- The provider retries **3 times, at 1 s, 2 s and 4 s**, on connection refused, 5xx
  (cfp-shaper answers 502 when teamclaude is down) and 429. That retry covers a
  request only **until its response headers arrive**
  (`crates/goose-providers/src/anthropic.rs`, `post_messages`). A gap of under
  about 7 s that falls before a request starts is absorbed. A longer one ends the
  turn with `LLM provider error`.
- A response that is already streaming when the proxy goes away is not retried by
  the provider. Expect the turn to end with an error. This is read from the
  source, not tested.
- `goose-turn-resume` resumes only turns cut by a **goose-serve restart**. A turn
  ended by a provider error stays ended until someone prompts that session again.

To see goose sessions that are mid-turn right now: `honk list | grep running`.

## Switching safely from inside an agent session

```
- [ ] hostname matches the target
- [ ] git fetch; root has nothing beyond origin/main; throwaway worktree at origin/main (never pull/reset the shared root)
- [ ] switch-impact.sh in that worktree; read every WATCHED unit's row
- [ ] watched unit bounces + `honk list` shows running turns or a live window -> wait, or get the owner's OK
- [ ] switch from the worktree
- [ ] verify: new version active, watched units' ActiveEnterTimestamp
```

**Which checkout.** A switch deploys the whole tree it is run from. A worktree
made from freshly fetched `origin/main` has every change that has landed, and it
leaves alone the shared root, where other sessions' uncommitted work lives. A
stale branch or a worktree carrying unmerged edits is what silently reverts
other people's changes.

```bash
cd ~/projects/workstation && git fetch -q
git log --oneline origin/main..HEAD          # must print nothing (else: root hotfix; see the rebuilding skill)
wt=$(mktemp -d) && git worktree add --detach "$wt" origin/main
cd "$wt" && .agents/skills/predicting-switch-restarts/switch-impact.sh .
sudo nixos-rebuild switch --flake ".#$(hostname)"              # system
home-manager switch --flake .#dev                              # home: .#dev on devbox, .#cloudbox on cloudbox
cd - && git worktree remove --force "$wt"
```

**Your own session survives either switch.** Neither switch restarts goose-serve
or the opencode serves (rows above), so the shell running it is not killed.
While the switch runs, your turn is blocked on a tool call rather than waiting
on a model request, so a cfp-shaper or teamclaude bounce in the middle does not
cut it. The sessions at risk are the **other** ones with a request in flight.
On cloudbox, an explicit `systemctl restart` of the serve pool or the door, run
from a session on that pool, does kill your own session; see the `rebuilding`
skill.

**Verify afterwards:**

```bash
systemctl show cfp-shaper goose-serve -p Id,ActiveEnterTimestamp,ExecStart --value | grep -v '^$'
systemctl --user show teamclaude honkd -p Id,ActiveEnterTimestamp --value
```

A watched unit with a start time after your switch was restarted by it.
