# Claude Code version devbox's opencode serves REPORT to Anthropic, overriding
# the version bundled in @ex-machina/opencode-anthropic-auth.
#
# Anthropic gates model access on the reported Claude Code version server-side.
# The pinned plugin (1.8.5) bundles 2.1.280; claude-fable-5-2 demands 2.1.290
# and 400s below it ("Claude Code 2.1.280 does not support this model; version
# 2.1.290 or newer is required"), which opencode shows as an EMPTY assistant
# turn. No published plugin reports >= 2.1.290 yet (1.8.6 = 2.1.284,
# 2.0.0-next.7 = 2.1.280; checked 2026-11-12), so devbox uses the plugin's own
# supported override, ANTHROPIC_CLAUDE_CODE_VERSION (config.js
# resolveClaudeCodeVersion). Verified on devbox 2026-11-12: with 2.1.290,
# fable-5-2 answers (including multi-turn tool use and a mid-session AGENTS.md
# change) and opus-5-5 still answers.
#
# Only devbox needs it: it is the one host whose `anthropic/` provider is live
# (teamclaude). cloudbox has no `anthropic` auth and macOS disables the
# provider, so there the plugin never shapes a request (cfp reports its own
# version on their Max leg).
#
# Consumers: the devbox serve unit env (home.devbox.nix) and the activation
# check in opencode-config.nix. Deliberately NOT a home.sessionVariables entry:
# other tools read the same variable name (eternal-machinery's letta-proxy),
# and a login-shell export would pin them to this value too.
#
# THE HAZARD: the plugin honours an override that is OLDER than its bundled
# constant. Plugin pins get bumped exactly when Anthropic gates a newer model,
# so a stale override would silently DOWNGRADE the reported version and 400
# every devbox turn. `forPluginPin` makes that a build failure:
# opencode-config.nix throws at eval if the anthropic-auth pin is not this
# value. When you bump the pin, re-check the new bundled constant: if it is
# >= `version`, delete this file and its two consumers; otherwise raise
# `forPluginPin` (and `version` if a newer model needs it).
{
  version = "2.1.290";
  forPluginPin = "1.8.5";
}
