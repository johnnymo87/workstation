# macOS-specific home-manager configuration
# Contains Darwin-only scripts, aliases, and settings
{ config, pkgs, lib, assetsPath, ... }:

{
  # Screenshot-to-devbox script (macOS only, uses screencapture + pbcopy)
  home.packages = [
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      runtimeInputs = [ pkgs.openssh ];
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
  ];

  # Alias for convenience
  programs.bash.shellAliases.ssdb = "screenshot-to-devbox";
}
