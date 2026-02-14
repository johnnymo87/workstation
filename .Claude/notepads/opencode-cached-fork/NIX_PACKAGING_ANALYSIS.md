# llm-agents.nix OpenCode Packaging Analysis

**Analyzed**: 2026-02-13  
**Purpose**: Document packaging requirements for opencode-cached custom package  
**Source**: `numtide/llm-agents.nix/packages/opencode/`

## Package Structure Overview

The llm-agents opencode package is a **prebuilt binary distribution** using `fetchurl` from GitHub releases, NOT a source build.

## Key Components to Replicate

### 1. Version and Hash Management

**Format** (`hashes.json`):
```json
{
  "version": "1.1.65",
  "hashes": {
    "aarch64-darwin": "sha256-...",
    "x86_64-darwin": "sha256-...",
    "x86_64-linux": "sha256-...",
    "aarch64-linux": "sha256-..."
  }
}
```

**Our needs**: Only `aarch64-linux` and `aarch64-darwin` (plan constraint).

### 2. Source Fetching

**URL Pattern**:
```nix
fetchurl {
  url = "https://github.com/anomalyco/opencode/releases/download/v${version}/${platformInfo.asset}";
  hash = hashes.${platform};
}
```

**Asset Naming**:
- Linux: `opencode-linux-arm64.tar.gz` (tarball)
- Darwin: `opencode-darwin-arm64.zip` (zip)

**For opencode-cached**: Replace `anomalyco/opencode` with `johnnymo87/opencode-cached` and version tag format `v${version}-cached`.

### 3. Build Inputs and Hooks

**Native Build Inputs** (package.nix:50-58):
- `makeWrapper` (both platforms)
- `unzip` (Darwin only - for .zip files)
- `wrapBuddy` (Linux only - ELF patching)

**Build Inputs** (package.nix:66-68):
- `stdenv.cc.cc.lib` (Linux only - provides libstdc++.so.6, libgcc_s.so.1)

**Install Check** (package.nix:60-64):
- `versionCheckHook` - verifies `--version` works
- `versionCheckHomeHook` - verifies binary runs

### 4. Build Flags

**Critical flags** (package.nix:70-73):
```nix
dontConfigure = true;  # No configure step needed
dontBuild = true;      # No build step - prebuilt binary
dontStrip = true;      # CRITICAL: strip removes compressed TypeScript code
```

### 5. Unpack Phase

**Platform-specific unpacking** (package.nix:75-86):
- Darwin (`.zip`): `unzip $src`
- Linux (`.tar.gz`): `tar -xzf $src`

Result: Binary file named `opencode` in current directory.

### 6. Install Phase (THE CRITICAL PART)

**Binary installation** (package.nix:88-104):
```nix
installPhase = ''
  runHook preInstall

  mkdir -p $out/bin
  install -m755 opencode $out/bin/opencode

  # Wrap to add fzf and ripgrep to PATH
  wrapProgram $out/bin/opencode \
    --prefix PATH : ${lib.makeBinPath [fzf ripgrep]}

  runHook postInstall
'';
```

**Runtime dependencies added to PATH**:
- `fzf` - fuzzy finder (used by opencode for file selection)
- `ripgrep` - fast grep (used by opencode for code search)

### 7. Linux-Specific: ELF Patching

**How wrapBuddy works** (implicit from nativeBuildInputs):
- Automatically patches ELF interpreter and RPATH
- Links against `stdenv.cc.cc.lib` (libstdc++, libgcc)
- Equivalent to `autoPatchelfHook` but numtide's custom wrapper

**For our package**: Use `autoPatchelfHook` (more standard) or replicate wrapBuddy's behavior.

### 8. Platform Map

**System to asset mapping** (package.nix:20-37):
```nix
platformMap = {
  x86_64-linux = { asset = "opencode-linux-x64.tar.gz"; isZip = false; };
  aarch64-linux = { asset = "opencode-linux-arm64.tar.gz"; isZip = false; };
  x86_64-darwin = { asset = "opencode-darwin-x64.zip"; isZip = true; };
  aarch64-darwin = { asset = "opencode-darwin-arm64.zip"; isZip = true; };
};
```

**Our constraint**: Only support `aarch64-linux` and `aarch64-darwin` (plan requirement).

## Minimum Derivation Template

```nix
{ lib, stdenv, fetchurl, makeWrapper, unzip, autoPatchelfHook, fzf, ripgrep }:

let
  pname = "opencode-cached";
  version = "1.1.65";  # Match upstream tag
  
  platformMap = {
    aarch64-linux = {
      asset = "opencode-linux-arm64.tar.gz";
      hash = "sha256-...";  # From CI release
      isZip = false;
    };
    aarch64-darwin = {
      asset = "opencode-darwin-arm64.zip";
      hash = "sha256-...";  # From CI release
      isZip = true;
    };
  };
  
  platform = stdenv.hostPlatform.system;
  platformInfo = platformMap.${platform} or (throw "Unsupported: ${platform}");
  
  src = fetchurl {
    url = "https://github.com/johnnymo87/opencode-cached/releases/download/v${version}-cached/${platformInfo.asset}";
    hash = platformInfo.hash;
  };
in
stdenv.mkDerivation {
  inherit pname version src;
  
  nativeBuildInputs = [
    makeWrapper
  ] ++ lib.optionals platformInfo.isZip [ unzip ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
  ];
  
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  
  unpackPhase = ''
    runHook preUnpack
    ${if platformInfo.isZip then "unzip $src" else "tar -xzf $src"}
    runHook postUnpack
  '';
  
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 opencode $out/bin/opencode
    wrapProgram $out/bin/opencode \
      --prefix PATH : ${lib.makeBinPath [ fzf ripgrep ]}
    runHook postUnpack
  '';
  
  meta = {
    description = "OpenCode with PR #5422 prompt caching improvements";
    homepage = "https://github.com/johnnymo87/opencode-cached";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" "aarch64-darwin" ];
    mainProgram = "opencode";
  };
}
```

## Critical Findings for Task 4

1. **Replace `wrapBuddy` with `autoPatchelfHook`**: More standard, same effect
2. **Hash format**: Use `sha256-...` (SRI format), compute from CI release with `nix hash file`
3. **URL change**: `anomalyco/opencode` → `johnnymo87/opencode-cached`, tag `v${version}-cached`
4. **Asset naming**: Our CI must produce exactly `opencode-linux-arm64.tar.gz` and `opencode-darwin-arm64.zip`
5. **No version pinning needed**: Can update version + hashes inline or via separate file

## Questions for Task 4

1. **Hash update strategy**: Manual update after each CI release, or automated?
   - Recommendation: Manual initially, automate later if needed
2. **Package location**: Inline in `flake.nix` or separate `pkgs/opencode-cached/default.nix`?
   - Recommendation: Inline initially (simpler), move to `pkgs/` if it grows
3. **Override strategy**: Replace `llmPkgs.opencode` or use overlay?
   - Recommendation: Direct replacement in `home.base.nix` with comment explaining why

## Evidence

- Source analysis: `/tmp/llm-agents-opencode-package.nix`
- Hash format: `/tmp/llm-agents-opencode-hashes.json`
- Current derivation: `.Claude/evidence/task-3-package-analysis.txt`
