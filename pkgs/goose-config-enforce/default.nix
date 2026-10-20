{ pkgs }:

# goose-config-enforce -- apply a declared extension enabled-set to goose's
# WRITABLE ~/.config/goose/config.yaml on every home-manager switch, touching
# nothing else in the file. See goose-config-enforce.sh for the behaviour and
# test.sh (run by checks.goose-config-enforce) for what it must not touch.
pkgs.writeShellApplication {
  name = "goose-config-enforce";
  runtimeInputs = [ pkgs.yq-go pkgs.jq pkgs.coreutils ];
  # SC2016: the single-quoted yq programs use yq variables ($e), not shell ones.
  excludeShellChecks = [ "SC2016" ];
  text = builtins.readFile ./goose-config-enforce.sh;
}
