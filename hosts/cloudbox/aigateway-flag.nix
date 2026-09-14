# Path to the aigateway operator-intent flag, as a bare string.
#
# This lives in its own file because it has THREE readers that must agree, in
# two different flake outputs (nixosConfigurations and homeConfigurations):
#
#   1. systemd.services.aigateway   -- ConditionPathExists (hosts/cloudbox/configuration.nix)
#   2. systemd.services.aigateway-canary -- decides whether a down gateway is a
#      breakage or a legitimate opt-out (same file)
#   3. home.activation.injectAigatewayBaseUrl -- decides whether opencode's
#      gemini provider points at :8080 (users/dev/opencode-config.nix)
#
# A copy-pasted string in three places is a silent drift hazard: the failure it
# produces is "opencode points at a gateway that is gated off", which nothing
# reports. One file, imported by both, removes that class entirely.
#
# Changing this path requires migrating the live flag by hand -- a rebuild will
# happily gate the unit on a path that does not exist yet, and the first thing
# you would notice is the gateway not coming back after a reboot.
"/var/lib/aigateway/enabled"
