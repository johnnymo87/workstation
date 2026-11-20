# Models honk offers when switching a goose session's model (`/model`, the
# `ctrl+x m` picker, `honk launch --model`). honkd reads this file through
# `--models-file` on every `_honk/model/list` request and lists these first,
# ahead of goose's own model list, which for gcp_vertex_ai is an outdated
# static list (Claude 4.x, Gemini 2.5/3.x) without most of the models below.
#
# Keys are goose provider names; ids are goose's bare model ids, not opencode's
# `provider/model@default` form. goose switches models only within a session's
# provider, so only the session's provider's entries are offered.
#
# Each id below answered through goose's gcp_vertex_ai provider on cloudbox on
# 2026-11-19 (`GOOSE_PROVIDER=gcp_vertex_ai GOOSE_MODEL=<id> goose run
# --no-session --text "Reply with exactly: ok"`). Mirrors the Vertex Claude and
# Gemini models in opencode's config (users/dev/opencode-config.nix) minus the
# superseded ones. Bead honk-9qf.15.7.
{ pkgs }:
pkgs.writeText "honk-models.json" (builtins.toJSON {
  providers.gcp_vertex_ai = [
    { id = "claude-opus-5-5"; name = "Claude Opus 5.5"; }
    { id = "claude-opus-5"; name = "Claude Opus 5"; }
    { id = "claude-opus-4-8"; name = "Claude Opus 4.8"; }
    { id = "claude-opus-4-7"; name = "Claude Opus 4.7"; }
    { id = "claude-fable-5-2"; name = "Claude Fable 5.2"; }
    { id = "claude-fable-5-1"; name = "Claude Fable 5.1"; }
    { id = "claude-haiku-5-5"; name = "Claude Haiku 5.5"; }
    { id = "gemini-3.8-flash"; name = "Gemini 3.8 Flash"; }
    { id = "gemini-3.7-flash"; name = "Gemini 3.7 Flash"; }
    { id = "gemini-4-hydrogen"; name = "Gemini 4 Hydrogen"; }
    { id = "gemini-4-argon"; name = "Gemini 4 Argon"; }
  ];
})
