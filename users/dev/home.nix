# Home-manager entry point
# Auto-imports platform-specific modules based on current system
{ pkgs, lib, ... }:

{
  imports =
    [ ./home.base.nix ]
    ++ lib.optionals pkgs.stdenv.isLinux  [ ./home.linux.nix ]
    ++ lib.optionals pkgs.stdenv.isDarwin [ ./home.darwin.nix ];
}
