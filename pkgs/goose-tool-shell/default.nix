# The shell goose-serve's developer extension runs every tool command through
# (GOOSE_SHELL on the goose-serve unit, both hosts). Bead workstation-pp9r.4.
#
# WHY: every goose tool shell is a child in goose-serve's own cgroup, so a
# command that pushes the unit to its MemoryMax makes the kernel pick an OOM
# victim from goose AND its shells together. It picks the highest badness, which
# is roughly RSS, so a many-worker job (cargo, make -j, vitest) whose workers are
# each smaller than goose (~0.9G) gets goose itself killed -- and with it every
# goose turn on the host, the stall-watch coordinators included.
#
# WHAT: raise this process's oom_score_adj to a floor, then exec the real bash.
# oom_score_adj is inherited across fork, so the command and everything it
# spawns carry the floor. Badness adds adj * (cgroup limit) / 1000, so at 500
# every shell descendant outranks goose (adj 0) by half the cap's worth of
# pages: 7G-equivalent at cloudbox's 14G, 3G at devbox's 6G -- more than goose's
# whole RSS, whatever size the descendant is. The unit's OOMScoreAdjust cannot do
# this, because goose's children inherit it.
#
# Named `bin/bash`, not something descriptive, ON PURPOSE: goose tells the model
# "Commands run under `<file name of GOOSE_SHELL>`" in the shell tool's
# description. Keeping it `bash` keeps that text, and so the prompt cache,
# byte-identical. `exec -a bash` keeps the shell's $0 what it was, and `exec`
# keeps the pid, which goose's process-group kill (fork patch 4) relies on.
#
# NOT a BASH_ENV hook: in the unit's environment that would also run in
# goose-serve-start (a bash script) before it execs goose, raising goose itself,
# and in every bash any child ever starts, MCP extension wrappers included.
{ pkgs
, lib ? pkgs.lib
  # The bash goose ran before this wrapper existed: `bash` resolved on the
  # unit's PATH, which leads with config.system.path, i.e. bashInteractive.
, bash ? pkgs.bashInteractive
, oomScoreAdjFloor ? 500
}:

let
  wrapper = pkgs.writeShellApplication {
    name = "goose-tool-shell";
    runtimeInputs = [ ];
    text = ''
      REAL_BASH="${bash}/bin/bash"
      OOM_SCORE_ADJ_FLOOR="${toString oomScoreAdjFloor}"

      # RAISE ONLY, never lower: a caller that already asked to be killed
      # first should stay that way. Never fatal and never noisy: any output
      # here would be prepended to every tool call's output.
      #
      # Not a guarantee: an unprivileged descendant may lower its own value
      # again, down to oom_score_adj_min (0 for goose-serve), and then it
      # competes with goose on size alone, as before this wrapper.
      #
      # Consequence: if goose-serve is ever given OOMScoreAdjust >= the floor,
      # this no-ops and goose ties with its shells again. Keep the unit below it.
      cur_adj=""
      if { read -r cur_adj < /proc/self/oom_score_adj; } 2>/dev/null \
        && [ "$cur_adj" -lt "$OOM_SCORE_ADJ_FLOOR" ] 2>/dev/null; then
        { echo "$OOM_SCORE_ADJ_FLOOR" > /proc/self/oom_score_adj; } 2>/dev/null || true
      fi

      exec -a bash "$REAL_BASH" "$@"
    '';
  };
in
pkgs.runCommand "goose-tool-shell"
{
  meta = {
    description = "bash for goose tool commands, with oom_score_adj raised so the OOM killer prefers them to goose";
    platforms = lib.platforms.linux;
  };
} ''
  mkdir -p $out/bin
  ln -s ${wrapper}/bin/goose-tool-shell $out/bin/bash
''
