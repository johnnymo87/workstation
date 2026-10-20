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
        self.assertEqual(r["settings"], {"goose_provider": "gcp_vertex_ai", "goose_model": "claude-opus-5-5"})
        self.assertEqual(r["description"], "Read-only advisor — architecture")
        exts = {e["name"]: e for e in r["extensions"]}
        self.assertEqual(set(exts), {"developer", "analyze", "skills", "ro-shell"})
        self.assertEqual(exts["developer"]["available_tools"], ["tree", "read_image"])
        self.assertEqual(exts["ro-shell"]["cmd"], KW["ro_shell_cmd"])
        self.assertEqual(exts["ro-shell"]["available_tools"], ["shell"])
        self.assertTrue(r["instructions"].startswith("You advise."))
        self.assertIn("read-only", r["instructions"])

    def test_implementer_role(self):
        r = g.build_role("implementer", RW, **KW)
        exts = {e["name"]: e for e in r["extensions"]}
        self.assertEqual(set(exts), {"developer", "analyze", "skills"})
        self.assertNotIn("available_tools", exts["developer"])

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

    def test_unscoped_recipe_is_read_only_set(self):
        u = g.build_unscoped(KW["ro_shell_cmd"])
        self.assertEqual(sorted(e["name"] for e in u["extensions"]), ["analyze", "developer", "ro-shell", "skills"])

    def test_real_assets(self):
        agents = os.environ.get("GOOSE_ROLES_AGENTS_DIR")
        if not agents:
            self.skipTest("set GOOSE_ROLES_AGENTS_DIR")
        out = tempfile.mkdtemp()
        g.generate(agents, out, g.ROLES, **KW)
        files = sorted(os.listdir(os.path.join(out, "roles")))
        self.assertEqual(files, sorted(f"{r}.yaml" for r in g.ROLES))
        for role in g.ROLES:
            with open(os.path.join(out, "roles", f"{role}.yaml")) as fh:
                r = yaml.safe_load(fh)
            ro = "ro-shell" in [e["name"] for e in r["extensions"]]
            self.assertEqual(ro, role != "implementer", role)
        self.assertTrue(os.path.isfile(os.path.join(out, "unscoped.yaml")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
