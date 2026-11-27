# One source for goose's per-command scopes (bead workstation-6w7i.7).
#
# Read by BOTH sides of a boundary nothing else connects:
#   - the NixOS goose-serve unit (hosts/*/configuration.nix), which builds
#     pkgs/goose-tool-shell with `sliceName` and the per-command caps, and
#   - home-manager (users/dev/goose-agent.nix), which ships the user slice the
#     scopes land in, with the aggregate cap.
# `systemd-run --slice=NAME` does not fail on an undeclared slice: it creates
# an uncapped transient one. So a rename on one side would stay green and
# silently unbounded; flake check `goose-agent-slice-wiring` guards it too.
#
# Sizing:
#   cloudbox (62G): oc-agent parity. 10G/2G per command, 20G/4G for all goose
#     tool commands together. They no longer count against goose-serve's 14G.
#   devbox (30G): 6G/1G per command, 10G/2G aggregate: the budget goose-serve's
#     10G cap gave goose AND its tools until now. The slice sits inside
#     user-1000.slice's 20G, so goose tools now share that bound with the
#     opencode serves instead of adding 10G beside it.
{
  sliceName = "goose-agent";
  hosts = {
    cloudbox = {
      scopeMemoryMax = "10G";
      scopeMemorySwapMax = "2G";
      sliceMemoryMax = "20G";
      sliceMemorySwapMax = "4G";
    };
    devbox = {
      scopeMemoryMax = "6G";
      scopeMemorySwapMax = "1G";
      sliceMemoryMax = "10G";
      sliceMemorySwapMax = "2G";
    };
  };
}
