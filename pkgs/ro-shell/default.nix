# ro-shell: stdio MCP server whose one `shell` tool runs bash with a read-only
# git shim first on PATH. Declared by goose's read-only role recipes
# (pkgs/goose-roles) in place of developer's shell. Accident guard, not a sandbox.
# Design: docs/plans/2026-10-20-goose-subagent-roles-design.md
{ lib, python3, git, bash, makeWrapper }:

python3.pkgs.buildPythonApplication {
  pname = "ro-shell";
  version = "0.1.0";
  format = "other";
  src = ./.;
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  propagatedBuildInputs = [ python3.pkgs.mcp ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/libexec/ro-shell/bin
    cp ro_shell.py $out/bin/ro-shell
    cp ro_git.py $out/libexec/ro-shell/bin/git
    substituteInPlace $out/libexec/ro-shell/bin/git \
      --replace-fail '@realGit@' '${git}/bin/git' \
      --replace-fail '@tmpRoots@' '/tmp'
    chmod +x $out/bin/ro-shell $out/libexec/ro-shell/bin/git
    runHook postInstall
  '';

  makeWrapperArgs = [
    "--set" "RO_SHELL_SHIM_DIR" "${placeholder "out"}/libexec/ro-shell/bin"
    "--set" "RO_SHELL_BASH" "${bash}/bin/bash"
  ];

  meta = {
    description = "Read-only shell MCP server for goose subagent roles";
    mainProgram = "ro-shell";
    platforms = lib.platforms.linux;
  };
}
