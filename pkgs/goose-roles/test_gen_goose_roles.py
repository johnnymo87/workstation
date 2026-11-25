#!/usr/bin/env python3
import os, sys, tempfile, unittest
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_goose_roles as g

RO = """---
description: Read-only advisor (opus-5-5 model) — architecture
mode: subagent
model: anthropic/claude-opus-5-5
variant: high
permission:
  write: deny
  edit: deny
  bash:
    "*": allow
---
You advise.
"""
RW = """---
description: Implementer — does one task
mode: subagent
model: anthropic/claude-sonnet-5-5
tools:
  datadog*: false
---
You implement.
"""
EXAMPLES = """---
description: |
  Use this agent when a step is done. Examples: <example>Context: x user: "y"</example>
model: anthropic/claude-sonnet-5-5
permission:
  write: deny
  edit: deny
---
Review.
"""
KW = dict(ro_shell_cmd="/nix/store/x-ro-shell/bin/ro-shell", provider="gcp_vertex_ai",
          opus_model="claude-opus-5-5", sonnet_model="claude-opus-5-5")


class GenTest(unittest.TestCase):
    def test_read_only_role(self):
        r = g.build_role("oracle", RO, **KW)
        self.assertEqual(r["settings"], {"goose_provider": "gcp_vertex_ai", "goose_model": "claude-opus-5-5",
                                         "max_turns": 80, "thinking_effort": "high"})
        self.assertEqual(r["description"], "Read-only advisor — architecture")
        exts = {e["name"]: e for e in r["extensions"]}
        self.assertEqual(set(exts), {"developer", "analyze", "skills", "ro-shell"})
        self.assertEqual(exts["developer"]["available_tools"], ["tree", "read_image"])
        self.assertEqual(exts["ro-shell"]["cmd"], KW["ro_shell_cmd"])
        self.assertEqual(exts["ro-shell"]["available_tools"], ["shell"])
        self.assertTrue(r["instructions"].startswith("You advise."))
        self.assertIn("read-only", r["instructions"])
        self.assertIn("throwaway repos you create under $TMPDIR (your private scratch dir) are unrestricted, except pushing to non-local remotes", r["instructions"])
        self.assertIn("environment limitation, not as a test failure", r["instructions"])

    def test_implementer_role(self):
        r = g.build_role("implementer", RW, **KW)
        exts = {e["name"]: e for e in r["extensions"]}
        self.assertEqual(set(exts), {"developer", "analyze", "skills"})
        self.assertNotIn("available_tools", exts["developer"])

    def test_max_turns_per_role(self):
        # goose's subagent default is 25 turns; every real SDD run on 2026-11-16 took more.
        self.assertEqual(g.build_role("implementer", RW, **KW)["settings"]["max_turns"], 250)
        for src in (RO, EXAMPLES):
            self.assertEqual(g.build_role("x", src, **KW)["settings"]["max_turns"], 80)

    def test_every_role_thinks_high(self):
        # A medium worker lead must not drag its roles down (workstation-6w7i.20).
        for src in (RO, RW, EXAMPLES):
            self.assertEqual(g.build_role("x", src, **KW)["settings"]["thinking_effort"], "high")

    def test_no_role_gets_summon(self):
        for src in (RO, RW, EXAMPLES):
            names = [e["name"] for e in g.build_role("x", src, **KW)["extensions"]]
            self.assertNotIn("summon", names)

    def test_examples_stripped_from_description(self):
        self.assertEqual(g.build_role("cr", EXAMPLES, **KW)["description"], "Use this agent when a step is done.")

    def test_inconsistent_permissions_rejected(self):
        bad = RO.replace("  edit: deny\n", "")
        with self.assertRaises(g.GenError):
            g.build_role("x", bad, **KW)

    def test_template_syntax_rejected(self):
        for tok in ("{{", "{%", "{#"):
            with self.subTest(tok=tok), self.assertRaises(g.GenError):
                g.build_role("x", RO.replace("You advise.", f"bad {tok} x"), **KW)

    def test_unknown_model_rejected(self):
        with self.assertRaises(g.GenError):
            g.build_role("x", RO.replace("anthropic/claude-opus-5-5", "openai/gpt-6-astra"), **KW)

    def test_twin_roles_generation(self):
        base_role = g.build_role("oracle", RO, **KW)
        for provider in ("gcp_vertex_ai", "anthropic"):
            kw = dict(KW, provider=provider)
            # astra twin
            r_astra = g.build_role("oracle", RO, twin="astra", **kw)
            self.assertEqual(r_astra["title"], "oracle-astra")
            self.assertEqual(r_astra["settings"]["goose_provider"], "codex_lb")
            self.assertEqual(r_astra["settings"]["goose_model"], "gpt-6-astra")
            self.assertEqual(r_astra["settings"]["max_turns"], 80)
            self.assertEqual(r_astra["settings"]["thinking_effort"], "high")
            self.assertEqual(r_astra["instructions"], base_role["instructions"])
            self.assertEqual(r_astra["extensions"], base_role["extensions"])
            self.assertIn("CAUTION — use this gpt-6-astra variant ONLY when the user explicitly asks for it; otherwise default to oracle", r_astra["description"])

            # fable twin
            r_fable = g.build_role("oracle", RO, twin="fable", **kw)
            self.assertEqual(r_fable["title"], "oracle-fable")
            self.assertEqual(r_fable["settings"]["goose_provider"], provider)
            self.assertEqual(r_fable["settings"]["goose_model"], "claude-fable-5-2")
            self.assertEqual(r_fable["settings"]["max_turns"], 80)
            self.assertEqual(r_fable["settings"]["thinking_effort"], "high")
            self.assertEqual(r_fable["instructions"], base_role["instructions"])
            self.assertEqual(r_fable["extensions"], base_role["extensions"])
            self.assertIn("CAUTION — use this fable-5-2 variant ONLY when the user explicitly asks for it; otherwise default to oracle", r_fable["description"])

    def test_twin_source_without_opus_pin_dies(self):
        for bad_src in (RW, RO.replace("anthropic/claude-opus-5-5", "anthropic/claude-sonnet-5-5"),
                        RO.replace("anthropic/claude-opus-5-5", "openai/gpt-6-astra")):
            with self.subTest(src=bad_src):
                with self.assertRaises(g.GenError):
                    g.build_role("oracle", bad_src, twin="astra", **KW)
                with self.assertRaises(g.GenError):
                    g.build_role("oracle", bad_src, twin="fable", **KW)

    def test_base_role_rejects_gpt_model(self):
        # map_model accepts gpt-* ids ONLY for the astra twin, never for base roles
        with self.assertRaises(g.GenError):
            g.build_role("oracle", RO, **dict(KW, opus_model="gpt-6-astra"))

    def test_gemini_worker_model(self):
        # cloudbox: sonnet-tier roles run Gemini on gcp_vertex_ai, like opencode's sddModel.
        kw = dict(KW, sonnet_model="gemini-3.8-flash")
        self.assertEqual(g.build_role("implementer", RW, **kw)["settings"]["goose_model"], "gemini-3.8-flash")
        self.assertEqual(g.build_role("oracle", RO, **kw)["settings"]["goose_model"], "claude-opus-5-5")

    def test_gemini_needs_vertex_provider(self):
        # The anthropic provider (devbox) cannot serve Gemini; the role would fail every delegate.
        with self.assertRaises(g.GenError):
            g.build_role("implementer", RW, **dict(KW, provider="anthropic", sonnet_model="gemini-3.8-flash"))

    def test_unscoped_recipe_is_read_only_set(self):
        u = g.build_unscoped(KW["ro_shell_cmd"])
        self.assertEqual(sorted(e["name"] for e in u["extensions"]), ["analyze", "developer", "ro-shell", "skills"])

    def test_real_assets(self):
        agents = os.environ.get("GOOSE_ROLES_AGENTS_DIR")
        if not agents:
            self.skipTest("set GOOSE_ROLES_AGENTS_DIR")
        out = tempfile.mkdtemp()
        g.generate(agents, out, g.ROLES, **KW)
        expected_roles = sorted(
            list(g.ROLES)
            + [f"{b}-astra" for b in g.TWIN_BASES]
            + [f"{b}-fable" for b in g.TWIN_BASES]
        )
        files = sorted(os.listdir(os.path.join(out, "roles")))
        self.assertEqual(files, sorted(f"{r}.yaml" for r in expected_roles))
        for role in expected_roles:
            with open(os.path.join(out, "roles", f"{role}.yaml")) as fh:
                r = yaml.safe_load(fh)
            ro = "ro-shell" in [e["name"] for e in r["extensions"]]
            self.assertEqual(ro, role != "implementer", role)
            self.assertEqual(r["settings"]["max_turns"], 80 if ro else 250, role)
            self.assertEqual(r["settings"]["thinking_effort"], "high", role)
        self.assertTrue(os.path.isfile(os.path.join(out, "unscoped.yaml")))

    def test_unreachable_provider_rejected(self):
        # The recipe provider outranks every fallback, so a typo must fail the build.
        argv = sys.argv
        sys.argv = ["gen", "--agents-dir", "x", "--out", "y", "--ro-shell-cmd", "z",
                    "--provider", "gcp_vertex", "--opus-model", "m", "--sonnet-model", "m"]
        try:
            with self.assertRaises(SystemExit):
                g.main()
        finally:
            sys.argv = argv

    def test_deployed_roles_model_per_host(self):
        # The sonnet-tier roles mirror the model opencode gives the same agents on
        # that host: cloudbox Gemini via the gateway (sddModel); devbox
        # claude-sonnet-5-5 (the agents' own pin, not rewritten there; Jonathan
        # 2026-11-23, workstation-6w7i.29). oracle/adversarial-reviewer: Opus on both.
        # Twins: *-astra runs gpt-6-astra, *-fable runs claude-fable-5-2 on both hosts.
        missing = [k for k in ("DEPLOYED_ROLES_DEVBOX", "DEPLOYED_ROLES_CLOUDBOX") if not os.environ.get(k)]
        if missing:
            self.skipTest(f"set {', '.join(missing)}")
        sonnet_tier = {"implementer", "code-reviewer", "spec-reviewer"}
        tier_model = {"DEPLOYED_ROLES_CLOUDBOX": "gemini-3.8-flash", "DEPLOYED_ROLES_DEVBOX": "claude-sonnet-5-5"}
        all_roles = (
            list(g.ROLES)
            + [f"{b}-astra" for b in g.TWIN_BASES]
            + [f"{b}-fable" for b in g.TWIN_BASES]
        )
        for var in ("DEPLOYED_ROLES_DEVBOX", "DEPLOYED_ROLES_CLOUDBOX"):
            for role in all_roles:
                with self.subTest(host=var, role=role):
                    file_path = os.path.join(os.environ[var], "roles", f"{role}.yaml")
                    self.assertTrue(os.path.isfile(file_path), f"{file_path} must exist")
                    with open(file_path) as fh:
                        model = yaml.safe_load(fh)["settings"]["goose_model"]
                    if role.endswith("-astra"):
                        self.assertEqual(model, "gpt-6-astra")
                    elif role.endswith("-fable"):
                        self.assertEqual(model, "claude-fable-5-2")
                    elif role in sonnet_tier:
                        self.assertEqual(model, tier_model[var])
                    else:
                        self.assertEqual(model, "claude-opus-5-5")

    def test_deployed_roles_provider_per_host(self):
        # What home-manager actually deploys on each host (flake check wiring):
        # devbox has no Vertex, so its roles must not name gcp_vertex_ai.
        # astra twins run on codex_lb on both hosts; fable twins run on the host provider.
        want = {"DEPLOYED_ROLES_DEVBOX": "anthropic", "DEPLOYED_ROLES_CLOUDBOX": "gcp_vertex_ai"}
        missing = [k for k in want if not os.environ.get(k)]
        if missing:
            self.skipTest(f"set {', '.join(missing)}")
        all_roles = (
            list(g.ROLES)
            + [f"{b}-astra" for b in g.TWIN_BASES]
            + [f"{b}-fable" for b in g.TWIN_BASES]
        )
        for var, provider in want.items():
            roles_dir = os.path.join(os.environ[var], "roles")
            for role in all_roles:
                with self.subTest(host=var, role=role):
                    file_path = os.path.join(roles_dir, f"{role}.yaml")
                    self.assertTrue(os.path.isfile(file_path), f"{file_path} must exist")
                    with open(file_path) as fh:
                        r = yaml.safe_load(fh)
                    expected_provider = "codex_lb" if role.endswith("-astra") else provider
                    self.assertEqual(r["settings"]["goose_provider"], expected_provider)


if __name__ == "__main__":
    unittest.main(verbosity=2)
