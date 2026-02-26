# Declarative list of projects to maintain across machines.
# Each entry is cloned to ~/projects/<name> (Linux) or ~/Code/<name> (macOS).
#
# platforms: which machines get this project.
#   "all" = every machine (default if omitted)
#   "devbox" = Hetzner devbox only
# Add more tags as needed (e.g. "cloudbox", "darwin").
{
  workstation = {
    url = "git@github.com:johnnymo87/workstation.git";
  };
  pigeon = {
    url = "git@github.com:johnnymo87/pigeon.git";
  };
  superpowers = {
    url = "git@github.com:obra/superpowers.git";
  };

  # Platform-specific projects
  chatgpt-relay = {
    url = "git@github.com:johnnymo87/chatgpt-relay.git";
    platforms = [ "darwin" ];
  };
  eternal-machinery = {
    url = "git@github.com:johnnymo87/eternal-machinery.git";
    platforms = [ "devbox" ];
  };
  my-podcasts = {
    url = "git@github.com:johnnymo87/my-podcasts.git";
    platforms = [ "devbox" ];
  };

  # Add more projects as needed:
  # my-project = { url = "git@github.com:org/repo.git"; };
}
