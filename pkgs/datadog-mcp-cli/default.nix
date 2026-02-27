{
  lib,
  stdenv,
  fetchurl,
}:

# Datadog MCP auth proxy — acts as stdio MCP server, proxies to Datadog's
# Streamable HTTP endpoint. Supports API key auth (DD_API_KEY + DD_APP_KEY)
# or OAuth (datadog_mcp_cli login). Binary is unversioned (always latest).
let
  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://coterm.datadoghq.com/mcp-cli/datadog_mcp_cli-linux-arm64";
      hash = "sha256-qA4nKBt/6usF3ogJ4geYBZvGneW5oFgmU9W/cu1PJCE=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://coterm.datadoghq.com/mcp-cli/datadog_mcp_cli-macos-arm64";
      hash = "sha256-7DtQTdJaQt7HFRaEpgbqIXlCS5DbiqHDSjfhL+1OoyE=";
    };
  };
in

stdenv.mkDerivation {
  pname = "datadog-mcp-cli";
  # Unversioned binary — update by changing hashes
  version = "unstable";

  src = sources.${stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/datadog_mcp_cli
    runHook postInstall
  '';

  dontFixup = stdenv.isLinux; # Statically linked on Linux

  doCheck = false;

  meta = with lib; {
    description = "Datadog MCP auth proxy (stdio → Streamable HTTP)";
    homepage = "https://developer.datadoghq.com/";
    license = licenses.unfree;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "datadog_mcp_cli";
    platforms = [ "aarch64-linux" "aarch64-darwin" ];
  };
}
