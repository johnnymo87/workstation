# oc-tags: naming and maintaining tags

The tagging policy now lives in the `tagging-sessions` skill,
`assets/opencode/skills/tagging-sessions/SKILL.md`, where agents load it
automatically. The org-specific tag list is fetched from Confluence into that
skill's `INTERNAL.md` at home-manager activation (see `confluenceSkills` in
`users/dev/opencode-skills.nix`), so it never enters source control.
