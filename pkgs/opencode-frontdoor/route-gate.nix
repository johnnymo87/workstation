{
  lib,
  stdenv,
  nodejs_22,
  curl,
  opencodePatched,
  opencodeFrontdoor,
}:

stdenv.mkDerivation {
  pname = "opencode-frontdoor-route-gate";
  version = "1.0.0";

  # CRITICAL nix gotcha: the opencode store path must be a real dependency or it is not mounted in the sandbox.
  nativeBuildInputs = [
    nodejs_22
    curl
    opencodePatched
  ];

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    export TMPDIR=$(mktemp -d)
    export HOME="$TMPDIR/home"
    export XDG_CONFIG_HOME="$TMPDIR/config"
    export XDG_DATA_HOME="$TMPDIR/data"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

    PORT=49195
    SERVE_LOG="$TMPDIR/serve.log"
    DOC_JSON="$TMPDIR/doc.json"

    echo "Booting pinned opencode serve on loopback port $PORT..."
    ${opencodePatched}/bin/opencode serve --port $PORT --hostname 127.0.0.1 < /dev/null > "$SERVE_LOG" 2>&1 &
    SERVE_PID=$!

    cleanup() {
      if [ -n "$SERVE_PID" ] && kill -0 $SERVE_PID 2>/dev/null; then
        kill -9 $SERVE_PID 2>/dev/null || true
        wait $SERVE_PID 2>/dev/null || true
      fi
    }
    trap cleanup EXIT

    # A fixed port is safe here: the nix Linux sandbox gives each build its own
    # network namespace, so concurrent builds cannot collide on it.
    #
    # Generous bound (~60s). Cold-start is seconds, but a too-tight bound turns
    # this gate into a flaky build failure, which trains people to ignore it —
    # worse than not having the gate at all.
    echo "Polling http://127.0.0.1:$PORT/doc..."
    SUCCESS=0
    for _ in $(seq 1 120); do
      if curl -sf --connect-timeout 1 --max-time 3 "http://127.0.0.1:$PORT/doc" -o "$DOC_JSON" 2>/dev/null \
         && [ -s "$DOC_JSON" ]; then
        SUCCESS=1
        break
      fi
      # Fail fast (with the log) if the serve died rather than burning the bound.
      if ! kill -0 $SERVE_PID 2>/dev/null; then
        echo "ERROR: opencode serve exited before answering /doc."
        break
      fi
      sleep 0.5
    done

    if [ $SUCCESS -ne 1 ]; then
      echo "ERROR: opencode serve failed to answer /doc within timeout!"
      echo "=== Serve Log ==="
      cat "$SERVE_LOG" || true
      echo "================="
      exit 1
    fi

    echo "Running route gate against fetched /doc..."
    set +e
    node "${opencodeFrontdoor}/libexec/opencode-frontdoor/dist/route-gate.js" "$DOC_JSON"
    GATE_EXIT=$?
    set -e

    cleanup

    if [ $GATE_EXIT -ne 0 ]; then
      echo "ERROR: route gate failed with exit code $GATE_EXIT!"
      echo "=== Serve Log ==="
      cat "$SERVE_LOG" || true
      echo "================="
      exit $GATE_EXIT
    fi

    mkdir -p "$out"
    echo "PASS" > "$out/gate-result.txt"

    runHook postInstall
  '';

  meta = {
    description = "Build-time gate ensuring opencode serve /doc routes are classified in opencode-frontdoor";
    platforms = lib.platforms.unix;
  };
}
