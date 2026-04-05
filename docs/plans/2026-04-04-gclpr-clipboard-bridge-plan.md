# gclpr Clipboard Bridge Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace lemonade with gclpr for UTF-8-safe TCP clipboard bridging over mosh sessions.

**Architecture:** gclpr server on macOS (launchd) + gclpr client on remote hosts (Nix package) + NaCl key-pair auth via sops. Reuses existing persistent SSH dev tunnels with RemoteForward 2850.

**Tech Stack:** Nix, home-manager, nix-darwin, sops-nix, gclpr (Go), tmux, Neovim, launchd

**Design doc:** `docs/plans/2026-04-04-gclpr-clipboard-bridge-design.md`

---

### Task 1: Package gclpr as a Nix derivation

**Files:**
- Create: `pkgs/gclpr/default.nix`
- Modify: `flake.nix` (add gclpr to localPkgs)

**Step 1: Create the package**

Create `pkgs/gclpr/default.nix` following the same pattern as the opencode-patched derivation in `home.base.nix` (multi-platform fetchurl with prebuilt binaries). Use v2.2.1.

```nix
{ lib, stdenv, fetchurl, unzip, autoPatchelfHook }:

let
  version = "2.2.1";
  platforms = {
    aarch64-linux = {
      asset = "gclpr_linux_arm64.zip";
      hash = "sha256-C+4XWveoZhUp6H2AO+GTk5aNYxdSg8CG67lJp6zURWI=";
    };
    aarch64-darwin = {
      asset = "gclpr_darwin_arm64.zip";
      hash = "sha256-fReLnTjvxMa/35eL/4Hv+eNE8IDvQgcg5GrzPG+hITg=";
    };
    x86_64-linux = {
      asset = "gclpr_linux_amd64.zip";
      hash = "sha256-N7HeIzByA2/ZeOdBzZuBmN0yyxpr7cdKqdNryLkJnO4=";
    };
    x86_64-darwin = {
      asset = "gclpr_darwin_amd64.zip";
      hash = "sha256-ZO5gaN2LvjXh7LnpMUJOuse2jNy1GwIL5YTpy7qvPKs=";
    };
  };
  platformInfo = platforms.${stdenv.hostPlatform.system};
in stdenv.mkDerivation {
  pname = "gclpr";
  inherit version;
  src = fetchurl {
    url = "https://github.com/rupor-github/gclpr/releases/download/v${version}/${platformInfo.asset}";
    hash = platformInfo.hash;
  };
  nativeBuildInputs = [ unzip ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
  ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  unpackPhase = ''
    runHook preUnpack
    unzip $src
    runHook postUnpack
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 gclpr $out/bin/gclpr
    runHook postInstall
  '';
  meta = {
    description = "Clipboard sharing and browser-open bridge tool";
    homepage = "https://github.com/rupor-github/gclpr";
    license = lib.licenses.mit;
    mainProgram = "gclpr";
  };
}
```

**Step 2: Add gclpr to flake.nix localPkgs**

In `flake.nix`, find where `localPkgs` is defined (it calls `pkgs.callPackage` for each package in `pkgs/`). Add gclpr the same way the other packages are added:

```nix
gclpr = pkgs.callPackage ./pkgs/gclpr {};
```

**Step 3: Verify nix builds**

```bash
nix eval .#darwinConfigurations.Y0FMQX93RR-2.system --apply 'x: "ok"'
```

Expected: `"ok"`

**Step 4: Commit**

```bash
git add pkgs/gclpr/default.nix flake.nix
git commit -m "Add gclpr package for clipboard bridging

Prebuilt Go binary from GitHub releases. Replaces lemonade
which has an unfixed UTF-8 corruption bug."
```

---

### Task 2: Add gclpr key pair to sops and deploy key files

**Files:**
- Modify: `secrets/secrets.yaml` (add gclpr_private_key)
- Create: `assets/gclpr/key.pub` (binary, 32 bytes)
- Modify: `users/dev/home.base.nix` (add home.file for key.pub, activation for private key)
- Modify: `users/dev/home.devbox.nix` (declare sops secret)
- Modify: `users/dev/home.cloudbox.nix` (declare sops secret)
- Modify: `users/dev/home.darwin.nix` (add home.file for trusted)

We already generated a key pair during testing. The files are at `~/.gclpr/key` (64 bytes, private) and `~/.gclpr/key.pub` (32 bytes, public). The hex public key is `122dcc14fa37068a2d604a736279c32f9aa1a38958a76f292f61812421544670`.

**Step 1: Copy key.pub to assets**

```bash
mkdir -p assets/gclpr
cp ~/.gclpr/key.pub assets/gclpr/key.pub
```

**Step 2: Add private key to sops**

The private key needs to be base64-encoded for sops (it's binary). Use the value:
`6xNSi85V0npPPc8lMpGnUK3DKGEXqGXw6C+xtTng86YSLcwU+jcGii1gSnNiecMvmqGjiVinbykvYYEkIVRGcA==`

```bash
sops secrets/secrets.yaml
# Add: gclpr_private_key: 6xNSi85V0npPPc8lMpGnUK3DKGEXqGXw6C+xtTng86YSLcwU+jcGii1gSnNiecMvmqGjiVinbykvYYEkIVRGcA==
```

**Step 3: Declare sops secret in home.devbox.nix**

Add to the `sops.secrets` attrset in `home.devbox.nix`:

```nix
gclpr_private_key = {};
```

**Step 4: Declare sops secret in home.cloudbox.nix**

Same as devbox:

```nix
gclpr_private_key = {};
```

**Step 5: Deploy key.pub via home.file (cross-platform, in home.base.nix)**

In `home.base.nix`, add a `home.file` entry. This needs to go inside the existing attrset or be added as a new declaration. Only deploy on non-Darwin non-Crostini (remote Linux hosts that use gclpr as client):

```nix
home.file.".gclpr/key.pub" = lib.mkIf (!isDarwin && !isCrostini) {
  source = "${assetsPath}/gclpr/key.pub";
};
```

**Step 6: Add activation script to decode private key from sops (home.base.nix)**

The sops secret is base64-encoded. Decode it and write to `~/.gclpr/key` with correct permissions:

```nix
home.activation.deployGclprKey = lib.mkIf (!isDarwin && !isCrostini) (
  lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -f /run/secrets/gclpr_private_key ]; then
      mkdir -p "$HOME/.gclpr"
      chmod 700 "$HOME/.gclpr"
      ${pkgs.coreutils}/bin/base64 -d /run/secrets/gclpr_private_key > "$HOME/.gclpr/key"
      chmod 600 "$HOME/.gclpr/key"
    else
      echo "deployGclprKey: skipping (secret not available)"
    fi
  ''
);
```

**Step 7: Deploy trusted file on macOS (home.darwin.nix)**

In `home.darwin.nix`, add to the `home.file` attrset (or the `// { }` merge block):

```nix
".gclpr/trusted".text = "122dcc14fa37068a2d604a736279c32f9aa1a38958a76f292f61812421544670\n";
```

**Step 8: Verify nix builds**

```bash
nix eval .#darwinConfigurations.Y0FMQX93RR-2.system --apply 'x: "ok"'
```

**Step 9: Commit**

```bash
git add assets/gclpr/key.pub secrets/secrets.yaml users/dev/home.base.nix users/dev/home.devbox.nix users/dev/home.cloudbox.nix users/dev/home.darwin.nix
git commit -m "Add gclpr key pair via sops and home-manager

Private key encrypted in sops, deployed to ~/.gclpr/key on
remote hosts via activation script. Public key committed to
assets/ and deployed via home.file. Trusted keys file on
macOS contains the hex public key."
```

---

### Task 3: Replace lemonade with gclpr in packages and server

**Files:**
- Modify: `users/dev/home.base.nix` (swap lemonade for gclpr in packages)
- Modify: `users/dev/home.darwin.nix` (replace lemonade-server with gclpr server launchd agent)

**Step 1: Replace lemonade with gclpr in home.packages (home.base.nix)**

Find the lemonade entry in `home.packages`:

```nix
    # Remote clipboard (lemonade client talks to macOS server over SSH tunnel)
    pkgs.lemonade
```

Replace with:

```nix
    # Remote clipboard (gclpr client talks to macOS server over SSH tunnel)
    localPkgs.gclpr
```

**Step 2: Replace lemonade-server launchd agent (home.darwin.nix)**

Remove the entire `launchd.agents.lemonade-server` block and replace with:

```nix
  # gclpr clipboard server.
  # Exposes macOS pbcopy/pbpaste over signed TCP so remote sessions (via SSH
  # RemoteForward) can copy/paste to the local clipboard through mosh.
  launchd.agents.gclpr-server = {
    enable = true;
    config = {
      ProgramArguments = [
        "${localPkgs.gclpr}/bin/gclpr"
        "server"
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        LANG = "en_US.UTF-8";
        LC_CTYPE = "en_US.UTF-8";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/gclpr-server.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/gclpr-server.err.log";
    };
  };
```

Note: gclpr reads `~/.gclpr/trusted` for authorized keys, so `HOME` must be set in the launchd environment. The server listens on port 2850 (default) on localhost only.

Note: `localPkgs` must be available in the function arguments of `home.darwin.nix`. Check the file header -- if `localPkgs` is not in the destructuring, it may need to be passed through. Check how `home.base.nix` receives it and follow the same pattern. If `localPkgs` is not available in `home.darwin.nix`, use the gclpr package path directly or add `localPkgs` to the module arguments.

**Step 3: Verify nix builds**

```bash
nix eval .#darwinConfigurations.Y0FMQX93RR-2.system --apply 'x: "ok"'
```

**Step 4: Commit**

```bash
git add users/dev/home.base.nix users/dev/home.darwin.nix
git commit -m "Replace lemonade with gclpr for clipboard bridging

gclpr handles UTF-8 correctly, uses NaCl key-pair auth, and is
actively maintained. Server runs on port 2850 with explicit
UTF-8 locale for correct pbcopy/pbpaste encoding."
```

---

### Task 4: Update SSH tunnel port and tmux/nvim config

**Files:**
- Modify: `scripts/update-ssh-config.sh` (change RemoteForward 2489 to 2850)
- Modify: `assets/tmux/extra.conf` (change copy-command)
- Modify: `assets/nvim/lua/user/settings.lua` (change clipboard provider)

**Step 1: Update RemoteForward in devbox-tunnel**

In `scripts/update-ssh-config.sh`, change:

```
    # Lemonade clipboard (remote copy/paste to macOS)
    RemoteForward 2489 127.0.0.1:2489
```

To:

```
    # gclpr clipboard (remote copy/paste to macOS)
    RemoteForward 2850 127.0.0.1:2850
```

**Step 2: Update RemoteForward in cloudbox-tunnel**

Same change in the cloudbox-tunnel block.

**Step 3: Update tmux copy-command**

In `assets/tmux/extra.conf`, change:

```tmux
# Pipe tmux copy-mode selections to lemonade (works through mosh)
set -s copy-command 'lemonade copy'
```

To:

```tmux
# Pipe tmux copy-mode selections to gclpr (works through mosh)
set -s copy-command 'gclpr copy'
```

**Step 4: Update Neovim clipboard provider**

In `assets/nvim/lua/user/settings.lua`, replace the lemonade clipboard block:

```lua
-- Clipboard: use system clipboard
-- On remote hosts, use lemonade (TCP-based, works through mosh).
-- Falls back to OSC 52 if lemonade isn't available, then to default
-- provider detection (pbcopy/pbpaste on macOS).
local is_remote = vim.fn.has("mac") == 0 and vim.fn.has("macunix") == 0
if vim.fn.executable("lemonade") == 1 and is_remote then
  vim.g.clipboard = {
    name = "lemonade",
    copy = {
      ["+"] = { "lemonade", "copy", "--no-fallback-messages" },
      ["*"] = { "lemonade", "copy", "--no-fallback-messages" },
    },
    paste = {
      ["+"] = { "lemonade", "paste", "--no-fallback-messages" },
      ["*"] = { "lemonade", "paste", "--no-fallback-messages" },
    },
  }
elseif vim.env.SSH_TTY then
  vim.g.clipboard = "osc52"
end
vim.opt.clipboard = "unnamedplus"
```

With:

```lua
-- Clipboard: use system clipboard
-- On remote hosts, use gclpr (TCP-based, works through mosh).
-- Falls back to OSC 52 if gclpr isn't available, then to default
-- provider detection (pbcopy/pbpaste on macOS).
local is_remote = vim.fn.has("mac") == 0 and vim.fn.has("macunix") == 0
if vim.fn.executable("gclpr") == 1 and is_remote then
  vim.g.clipboard = {
    name = "gclpr",
    copy = {
      ["+"] = { "gclpr", "copy" },
      ["*"] = { "gclpr", "copy" },
    },
    paste = {
      ["+"] = { "gclpr", "paste" },
      ["*"] = { "gclpr", "paste" },
    },
  }
elseif vim.env.SSH_TTY then
  vim.g.clipboard = "osc52"
end
vim.opt.clipboard = "unnamedplus"
```

Note: gclpr doesn't need `--no-fallback-messages` -- it doesn't have that flag. Its error handling is clean by default.

**Step 5: Commit**

```bash
git add scripts/update-ssh-config.sh assets/tmux/extra.conf assets/nvim/lua/user/settings.lua
git commit -m "Update SSH tunnels, tmux, and nvim for gclpr

Change RemoteForward from 2489 to 2850 (gclpr default port).
Update tmux copy-command and Neovim clipboard provider to use
gclpr instead of lemonade."
```

---

### Task 5: Update documentation

**Files:**
- Modify: `.opencode/skills/osc52-clipboard/SKILL.md`
- Modify: `.opencode/skills/troubleshooting-devbox/SKILL.md`
- Modify: `AGENTS.md`

**Step 1: Update clipboard skill**

In `.opencode/skills/osc52-clipboard/SKILL.md`, replace all references to lemonade with gclpr. Update:
- Tool name: lemonade → gclpr
- Port: 2489 → 2850
- Test commands: `lemonade copy` → `gclpr copy`, `lemonade paste` → `gclpr paste`
- Note the key-pair auth setup requirement
- Keep OSC 52 fallback documentation unchanged

**Step 2: Update troubleshooting-devbox skill**

In `.opencode/skills/troubleshooting-devbox/SKILL.md`, update the port tables:
- Change port 2489 references to 2850
- Change "Lemonade clipboard" to "gclpr clipboard"

**Step 3: Update AGENTS.md if needed**

Check `AGENTS.md` for any lemonade references. The skill entry was already updated to "Clipboard (Lemonade & OSC 52)" -- change to "Clipboard (gclpr & OSC 52)".

**Step 4: Commit**

```bash
git add .opencode/skills/osc52-clipboard/SKILL.md .opencode/skills/troubleshooting-devbox/SKILL.md AGENTS.md
git commit -m "Update clipboard docs for gclpr migration

Replace lemonade references with gclpr across clipboard skill,
troubleshooting-devbox port tables, and AGENTS.md skill index."
```

---

### Task 6: Deploy and test

**Step 1: Push to remote**

```bash
git push origin HEAD:main
```

**Step 2: Deploy macOS**

```bash
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
```

Verify gclpr server is running:
```bash
launchctl list | grep gclpr
lsof -i :2850 -P -n
gclpr paste  # should return current clipboard contents
```

**Step 3: Re-run update-ssh-config.sh**

```bash
bash scripts/update-ssh-config.sh
grep 2850 ~/.ssh/config
```

Expected: Two lines showing `RemoteForward 2850 127.0.0.1:2850`

**Step 4: Restart dev tunnel launchd agents**

```bash
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.devbox-dev-tunnel
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.cloudbox-dev-tunnel
```

**Step 5: Deploy to devbox**

```bash
ssh devbox "cd ~/projects/workstation && git fetch && git checkout origin/main && sudo nixos-rebuild switch --flake .#devbox && nix run home-manager -- switch --flake .#dev"
```

Note: `sudo nixos-rebuild switch` is needed because sops secrets are declared at the NixOS level. Then `home-manager switch` deploys the key files and gclpr binary.

**Step 6: Test clipboard on devbox**

```bash
mosh devbox -- tmux new -s test
# In the mosh+tmux session:
echo "café résumé 日本語 🎉" | gclpr copy
# Cmd+V on macOS should paste "café résumé 日本語 🎉" with correct characters

gclpr paste
# Should return current macOS clipboard contents

# Neovim test:
nvim /tmp/test.txt
# Type some text with special chars, yank with yy
# Cmd+V on macOS should paste correctly
```

**Step 7: Deploy to cloudbox**

Same as devbox but with cloudbox-specific flake targets.

**Step 8: Test clipboard on cloudbox**

Same tests as devbox.

**Step 9: Clean up old lemonade artifacts**

On macOS, remove the old lemonade launchd agent if it's still registered:
```bash
launchctl bootout gui/$(id -u)/org.nix-community.home.lemonade-server 2>/dev/null || true
```

Verify no lemonade processes remain:
```bash
pgrep lemonade || echo "clean"
lsof -i :2489 || echo "port 2489 free"
```
