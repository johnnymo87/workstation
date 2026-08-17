# The worktree-guard pre-commit hook, packaged.
#
# WHY THIS EXISTS AT ALL: the hook is a plain asset whose shebang is
# `#!/bin/bash`, and it was deployed by copying that asset verbatim. Two
# problems fell out of that, found while wiring its test suite (workstation-dad9):
#
#   1. /bin/bash IS NOT DECLARED ANYWHERE IN THIS REPO. On cloudbox it happens to
#      exist as a root-owned symlink into dev's nix profile, created by hand at
#      some point and recorded nowhere. Nothing recreates it -- so a reprovisioned
#      host (see the setting-up-cloudbox skill) would deploy a hook that cannot
#      exec. Measured, so the failure mode is stated accurately: git then reports
#      `fatal: cannot exec '...': No such file or directory` and ABORTS the
#      commit, so the guard fails closed and loud rather than silently letting
#      commits through -- every commit in the three enrolled repos breaks until
#      someone recreates a symlink that is written down nowhere.
#      Every other script in this repo uses a bash store path in its shebang;
#      this asset was the only exception.
#   2. A nix build sandbox has no /bin/bash either (measured: /bin contains only
#      `sh`), so the hook's own 234-line test suite could not run as a check
#      while the shebang stayed as it was.
#
# Both problems have one fix, and it is the same artifact for both: patch the
# interpreter to a store path at build time. The test suite is then pointed at
# THIS package rather than at the raw asset, so what CI exercises is byte-for-byte
# what cloudbox deploys -- not a copy patched a second way for the sandbox's
# benefit.
#
# The output is a DIRECTORY, because git's core.hooksPath takes one; the suite
# sets that config, so a bare file would not be usable the way git uses it.
{ lib, runCommandLocal, bash }:

runCommandLocal "worktree-guard-hook" {
  meta = {
    description = "pre-commit hook refusing commits at a shared repo's primary root";
    platforms = lib.platforms.all;
  };
} ''
  mkdir -p $out
  install -m755 ${../../assets/git-hooks/pre-commit} $out/pre-commit

  # Explicit substitution rather than patchShebangs, which resolves the
  # interpreter from whatever is on the builder's PATH. Naming ${bash} pins it to
  # the same derivation every other bash shebang in this repo gets
  # (verified identical store path), and --replace-fail means a future edit to
  # the asset's shebang breaks the build instead of silently shipping an
  # unpatched hook.
  #
  # Note for the reader expecting plain bash: this nixpkgs aliases bash to
  # bashInteractive, so the resulting shebang reads bash-interactive-5.3p3. That
  # is the repo-wide convention (verified: the same store path the other shebangs
  # here resolve to), not an accident of this derivation.
  substituteInPlace $out/pre-commit \
    --replace-fail '#!/bin/bash' '#!${bash}/bin/bash'

  # A hook that is not executable fails silently-ish (git reports it cannot run
  # and aborts the commit), and a shebang that still points outside the store
  # would defeat the entire purpose of this derivation. Assert both.
  [ -x $out/pre-commit ] || { echo "hook is not executable" >&2; exit 1; }
  head -1 $out/pre-commit | grep -q '^#!/nix/store/' || {
    echo "hook shebang was not rewritten to a store path:" >&2
    head -1 $out/pre-commit >&2
    exit 1
  }
''
