#!/usr/bin/env python3
"""
pinentry-op: A pinentry wrapper that fetches GPG passphrase from 1Password.

This script implements the Assuan protocol used by gpg-agent to request
passphrases. On GETPIN, it attempts to fetch the passphrase from 1Password
using `op read`. If that fails, it falls back to pinentry-mac for GUI prompt.

Environment variables:
  OP_GPG_SECRET_REF: 1Password secret reference (e.g., "op://Vault/Item/field")
  PINENTRY_MAC_PATH: Path to pinentry-mac binary for fallback

The script handles these pinentry commands:
  - GETPIN: Fetch passphrase (main functionality)
  - SETDESC, SETPROMPT, SETTITLE, OPTION, etc.: Acknowledge and store
  - BYE: Clean exit
"""

import os
import subprocess
import sys

# Configuration from environment
OP_BIN = os.environ.get("OP_BIN", "/usr/bin/op")
OP_SECRET_REF = os.environ.get("OP_GPG_SECRET_REF", "")
PINENTRY_MAC = os.environ.get("PINENTRY_MAC_PATH", "")


def log(msg: str) -> None:
    """Log to stderr for debugging (gpg-agent ignores stderr)."""
    if os.environ.get("PINENTRY_OP_DEBUG"):
        sys.stderr.write(f"pinentry-op: {msg}\n")
        sys.stderr.flush()


def write(line: str) -> None:
    """Send a response line to gpg-agent."""
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    log(f">>> {line}")


def op_read(secret_ref: str) -> str | None:
    """Fetch a secret from 1Password using `op read`."""
    try:
        result = subprocess.run(
            [OP_BIN, "read", secret_ref],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            log(f"op read failed: {result.stderr.strip()}")
            return None
        passphrase = result.stdout
        # Remove trailing newline if present
        if passphrase.endswith("\n"):
            passphrase = passphrase[:-1]
        return passphrase
    except subprocess.TimeoutExpired:
        log("op read timed out")
        return None
    except Exception as e:
        log(f"op read error: {e}")
        return None


def fallback_pinentry(commands: list[tuple[str, str]]) -> str | None:
    """Fall back to pinentry-mac for GUI prompt."""
    if not PINENTRY_MAC:
        log("No fallback pinentry configured")
        return None

    try:
        proc = subprocess.Popen(
            [PINENTRY_MAC],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Read greeting
        proc.stdout.readline()

        # Replay stored commands
        for cmd, arg in commands:
            if arg:
                proc.stdin.write(f"{cmd} {arg}\n")
            else:
                proc.stdin.write(f"{cmd}\n")
            proc.stdin.flush()
            proc.stdout.readline()  # Read OK

        # Send GETPIN
        proc.stdin.write("GETPIN\n")
        proc.stdin.flush()

        # Read response
        passphrase = None
        while True:
            line = proc.stdout.readline().strip()
            if line.startswith("D "):
                passphrase = line[2:]
            elif line == "OK":
                break
            elif line.startswith("ERR"):
                log(f"Fallback pinentry error: {line}")
                break

        proc.stdin.write("BYE\n")
        proc.stdin.flush()
        proc.terminate()

        return passphrase
    except Exception as e:
        log(f"Fallback pinentry error: {e}")
        return None


def main() -> None:
    """Main pinentry protocol loop."""
    # Send greeting
    write("OK pinentry-op ready")

    # Store commands to replay to fallback if needed
    stored_commands: list[tuple[str, str]] = []

    while True:
        try:
            line = sys.stdin.readline()
        except KeyboardInterrupt:
            break

        if not line:
            break

        line = line.strip()
        log(f"<<< {line}")

        if not line:
            continue

        # Parse command and argument
        parts = line.split(" ", 1)
        cmd = parts[0].upper()
        arg = parts[1] if len(parts) > 1 else ""

        if cmd == "BYE":
            write("OK")
            break

        elif cmd == "GETPIN":
            passphrase = None

            # Try 1Password first
            if OP_SECRET_REF:
                log(f"Attempting op read for {OP_SECRET_REF}")
                passphrase = op_read(OP_SECRET_REF)

            # Fall back to pinentry-mac if 1Password fails
            if passphrase is None:
                log("Falling back to pinentry-mac")
                passphrase = fallback_pinentry(stored_commands)

            if passphrase is not None:
                write(f"D {passphrase}")
                write("OK")
            else:
                write("ERR 83886179 Operation cancelled")

        elif cmd in ("SETDESC", "SETPROMPT", "SETTITLE", "SETOK", "SETCANCEL",
                     "SETNOTOK", "SETERROR", "SETQUALITYBAR", "SETREPEAT",
                     "OPTION", "SETKEYINFO", "SETGENPIN", "SETTIMEOUT"):
            # Store these commands to replay to fallback pinentry
            stored_commands.append((cmd, arg))
            write("OK")

        elif cmd == "GETINFO":
            if arg == "pid":
                write(f"D {os.getpid()}")
                write("OK")
            elif arg == "version":
                write("D 1.0.0")
                write("OK")
            else:
                write("OK")

        elif cmd == "CONFIRM":
            # For confirm dialogs, always fall back to GUI
            result = fallback_pinentry(stored_commands + [("CONFIRM", "")])
            if result is not None:
                write("OK")
            else:
                write("ERR 83886179 Operation cancelled")

        elif cmd == "MESSAGE":
            # For message dialogs, always fall back to GUI
            fallback_pinentry(stored_commands + [("MESSAGE", "")])
            write("OK")

        else:
            # Unknown command - acknowledge
            write("OK")


if __name__ == "__main__":
    main()
