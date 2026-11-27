"""Wedge canary for goose-serve and honkd (bead workstation-6w7i.7).

One pass, run minutely by a user timer on cloudbox and devbox. ALERT-ONLY by
design: restarting goose-serve cuts every in-flight goose turn on the host.
Since workstation-6w7i.16 those turns are re-prompted (goose-turn-resume), but
a false positive would still cost every running turn its in-flight step, so a
human decides until the probe has a record. honkd is held to the same rule: a
honkd restart cuts every turn it relays, and goose-turn-resume does not cover
those (honkd either continues such a turn or records nothing).

"Frozen" means no ACP answer, not "process gone": systemd already restarts a
dead goose-serve (Restart=always). The probes:

  goose-serve  POST initialize on /acp, then session/list answered over the
               connection's SSE stream, then DELETE the connection. initialize
               alone is answered by the HTTP layer and the connection factory;
               session/list also needs the agent's session store, which is
               where a deadlock would show.
  honkd        `honk list --json` through honkd. Judged ONLY on a pass where
               goose answered: honkd's list goes upstream, so a goose wedge
               would otherwise page twice and blame honkd.

Three consecutive failed passes before alerting (a restart, a slow first
request after idle, a GC pause). Alerts go through opencode-drift-alert
(escalating backoff, dedup by signature); healthy passes clear its state so the
next episode starts fresh. Never exits non-zero for a probe result: a failed
canary unit would read as "the canary is broken".
"""

import http.client
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

THRESHOLD = int(os.environ.get("GOOSE_CANARY_THRESHOLD", "3"))
TIMEOUT = float(os.environ.get("GOOSE_CANARY_TIMEOUT", "15"))
SYSTEMCTL = os.environ.get("GOOSE_CANARY_SYSTEMCTL", "systemctl")


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None:
        print(f"goose-canary: {name} is not set", file=sys.stderr)
        sys.exit(2)
    return v


def log(msg):
    print(msg, flush=True)


# ---- probes -----------------------------------------------------------------

def probe_goose(host, port, secret, timeout=TIMEOUT):
    """Return None when goose answers ACP, else a one-line reason."""
    hdr = {
        "x-secret-key": secret,
        "content-type": "application/json",
        "accept": "application/json, text/event-stream",
    }
    deadline = time.monotonic() + timeout
    cid = None
    conns = []

    def conn(t):
        c = http.client.HTTPConnection(host, port, timeout=t)
        conns.append(c)
        return c

    try:
        c = conn(timeout)
        c.request("POST", "/acp", json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": 1, "clientCapabilities": {},
                       "clientInfo": {"name": "goose-canary", "version": "1"}},
        }), hdr)
        r = c.getresponse()
        body = r.read()
        cid = r.getheader("acp-connection-id")
        if r.status != 200 or not cid:
            return f"initialize: HTTP {r.status}, connection id {cid!r}"
        if "result" not in json.loads(body or b"{}"):
            return f"initialize: no result in {body[:200]!r}"

        left = max(1.0, deadline - time.monotonic())
        s = conn(left)
        s.request("GET", "/acp", headers={
            "x-secret-key": secret, "acp-connection-id": cid,
            "accept": "text/event-stream"})
        sr = s.getresponse()
        conns.append(sr)
        if sr.status != 200:
            return f"SSE stream: HTTP {sr.status}"

        h = dict(hdr)
        h["acp-connection-id"] = cid
        p = conn(left)
        p.request("POST", "/acp", json.dumps(
            {"jsonrpc": "2.0", "id": 2, "method": "session/list", "params": {}}), h)
        pr = p.getresponse()
        pr.read()
        if pr.status not in (200, 202):
            return f"session/list POST: HTTP {pr.status}"

        # The socket timeout bounds each readline; the deadline bounds the sum.
        while time.monotonic() < deadline:
            line = sr.fp.readline()
            if not line:
                return "session/list: SSE stream ended without an answer"
            line = line.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            try:
                msg = json.loads(line[5:])
            except ValueError:
                continue
            if msg.get("id") == 2:
                if "result" in msg:
                    return None
                return f"session/list: error {json.dumps(msg.get('error'))[:200]}"
        return f"session/list: no answer within {timeout:.0f}s"
    except Exception as e:  # timeouts, refused, reset, bad JSON
        return f"{type(e).__name__}: {e}"[:300]
    finally:
        for c in conns:
            c.close()
        if cid:
            try:
                d = http.client.HTTPConnection(host, port, timeout=3)
                d.request("DELETE", "/acp", headers={
                    "x-secret-key": secret, "acp-connection-id": cid})
                d.getresponse().read()
                d.close()
            except Exception:
                pass


def probe_honkd(honk_bin, timeout=TIMEOUT):
    try:
        p = subprocess.run([honk_bin, "list", "--json"], capture_output=True,
                           timeout=timeout, text=True)
    except subprocess.TimeoutExpired:
        return f"`honk list --json` gave no answer within {timeout:.0f}s"
    except OSError as e:
        return f"cannot run {honk_bin}: {e}"
    if p.returncode != 0:
        return f"`honk list --json` exit {p.returncode}: {p.stderr.strip()[:200]}"
    try:
        if not isinstance(json.loads(p.stdout), list):
            return "`honk list --json` did not return a JSON array"
    except ValueError:
        return f"`honk list --json` returned non-JSON: {p.stdout[:120]!r}"
    return None


# ---- state + alerting -------------------------------------------------------

def bump(state, name):
    f = state / f"{name}-fails"
    n = int(f.read_text() or 0) + 1 if f.exists() else 1
    f.write_text(str(n))
    return n


def clear(state, name):
    (state / f"{name}-fails").unlink(missing_ok=True)
    for a in state.glob(f"alert-{name}-*"):
        a.unlink(missing_ok=True)


def alert(alert_cmd, state, key, signature, text):
    # 900/14400: t=0, 15m, 45m, ... capped at one page per 4h (same as the
    # other canaries). drift-alert never exits non-zero.
    subprocess.run([alert_cmd, str(state / f"alert-{key}"), signature, text,
                    "900", "14400"], check=False, timeout=30)


def unit_state(unit, user):
    cmd = [SYSTEMCTL] + (["--user"] if user else []) + ["is-active", unit]
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=10).stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def forensics(state, unit, user, cgroup):
    """Bounded snapshot of the unit's main process and cgroup. Best effort."""
    ts = time.strftime("%Y%m%dT%H%M%S")
    d = state / f"wedge-{unit.split('.')[0]}-{ts}"
    d.mkdir(parents=True, exist_ok=True)
    olds = sorted(state.glob("wedge-*"))[:-10]
    for o in olds:
        for f in o.iterdir():
            f.unlink(missing_ok=True)
        o.rmdir()
    try:
        cmd = [SYSTEMCTL] + (["--user"] if user else []) + [
            "show", unit, "-p", "MainPID", "--value"]
        pid = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=10).stdout.strip()
        if pid and pid != "0":
            for name in ("status", "wchan", "stack", "syscall"):
                try:
                    (d / name).write_text(Path(f"/proc/{pid}/{name}").read_text())
                except OSError:
                    pass
            try:
                tasks = Path(f"/proc/{pid}/task")
                (d / "threads").write_text("\n".join(
                    f"{t.name} {Path(t, 'wchan').read_text()}"
                    for t in sorted(tasks.iterdir())))
            except OSError:
                pass
    except Exception:
        pass
    if cgroup:
        for name in ("memory.current", "memory.peak", "memory.events",
                     "memory.stat", "memory.pressure", "cpu.pressure"):
            try:
                (d / name).write_text(Path(cgroup, name).read_text())
            except OSError:
                pass
    return d


def reset_in_progress(lock="/tmp/reset-workspace.lock"):
    """True while reset-workspace holds its lock (it restarts goose-serve).
    Probe the FLOCK, not the file: the file is never unlinked."""
    if not os.path.exists(lock):
        return False
    import fcntl
    try:
        with open(lock) as f:
            fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
            fcntl.flock(f, fcntl.LOCK_UN)
        return False
    except OSError:
        return True


# ---- one pass ---------------------------------------------------------------

def main():
    host_name = env("GOOSE_CANARY_HOST")
    state = Path(env("GOOSE_CANARY_STATE"))
    state.mkdir(parents=True, exist_ok=True)
    alert_cmd = env("GOOSE_CANARY_ALERT")
    honk_bin = env("GOOSE_CANARY_HONK")
    secret_file = env("GOOSE_CANARY_SECRET_FILE")
    port = int(env("GOOSE_CANARY_PORT", "4080"))
    goose_unit = env("GOOSE_CANARY_GOOSE_UNIT", "goose-serve.service")
    honkd_unit = env("GOOSE_CANARY_HONKD_UNIT", "honkd.service")
    goose_cg = env("GOOSE_CANARY_GOOSE_CGROUP",
                   "/sys/fs/cgroup/system.slice/goose-serve.service")

    if reset_in_progress(env("GOOSE_CANARY_RESET_LOCK", "/tmp/reset-workspace.lock")):
        log("reset-workspace in progress; skipping this pass")
        return 0

    # ---- goose-serve ----
    gstate = unit_state(goose_unit, user=False)
    if gstate != "active":
        # Not a wedge. Restart=always handles a crash in seconds, so only a
        # unit that STAYS down is worth a page.
        n = bump(state, "goose-down")
        log(f"{goose_unit} is '{gstate}' ({n} consecutive passes)")
        if n >= THRESHOLD:
            alert(alert_cmd, state, "goose-down-x", "goose-down",
                  f"goose-serve on {host_name} has not been active for {n} minutes "
                  f"(state '{gstate}'). Every goose session on the host is "
                  f"unreachable.\n\nCheck: systemctl status goose-serve; "
                  f"journalctl -u goose-serve -n 80 --no-pager")
        return 0
    clear(state, "goose-down")

    try:
        secret = Path(secret_file).read_text().strip()
    except OSError as e:
        log(f"cannot read {secret_file}: {e}")
        return 0

    why = probe_goose("127.0.0.1", port, secret)
    if why:
        n = bump(state, "goose")
        log(f"goose-serve ACP probe failed ({n} consecutive): {why}")
        if n == THRESHOLD or (n > THRESHOLD and n % 15 == 0):
            dump = forensics(state, goose_unit, False, goose_cg)
            log(f"forensics in {dump}")
        if n >= THRESHOLD:
            alert(alert_cmd, state, "goose-wedge-x", "goose-wedge",
                  f"goose-serve on {host_name} is active but has not answered ACP "
                  f"for {n} consecutive minutes: {why}\n\n"
                  f"Every goose turn on the host is stalled. The canary does NOT "
                  f"restart it. A restart cuts every in-flight turn; goose-turn-resume "
                  f"re-prompts them within a minute or two (workstation-6w7i.16). "
                  f"Decide, then: sudo systemctl restart goose-serve.\n\nForensics: {state}/wedge-goose-serve-*\n"
                  f"Check: journalctl -u goose-serve -n 80 --no-pager")
        return 0
    clear(state, "goose")

    # ---- honkd (only judged while goose answers) ----
    hstate = unit_state(honkd_unit, user=True)
    if hstate != "active":
        n = bump(state, "honkd-down")
        log(f"{honkd_unit} is '{hstate}' ({n} consecutive passes)")
        if n >= THRESHOLD:
            alert(alert_cmd, state, "honkd-down-x", "honkd-down",
                  f"honkd on {host_name} has not been active for {n} minutes "
                  f"(state '{hstate}'); pigeon, stall-watch and honk launch all "
                  f"reach goose through it.\n\nCheck: systemctl --user status "
                  f"honkd; journalctl --user -u honkd -n 80 --no-pager")
        return 0
    clear(state, "honkd-down")

    why = probe_honkd(honk_bin)
    if why:
        n = bump(state, "honkd")
        log(f"honkd probe failed ({n} consecutive): {why}")
        if n == THRESHOLD:
            uid = os.getuid()
            dump = forensics(state, honkd_unit, True,
                             f"/sys/fs/cgroup/user.slice/user-{uid}.slice/"
                             f"user@{uid}.service/app.slice/{honkd_unit}")
            log(f"forensics in {dump}")
        if n >= THRESHOLD:
            alert(alert_cmd, state, "honkd-wedge-x", "honkd-wedge",
                  f"honkd on {host_name} is active and goose-serve answers ACP, "
                  f"but honkd has not answered for {n} consecutive minutes: {why}"
                  f"\n\nNot restarted automatically: a honkd restart cuts every "
                  f"turn it relays. Decide, then: systemctl --user restart honkd."
                  f"\n\nForensics: {state}/wedge-honkd-*\nCheck: journalctl --user "
                  f"-u honkd -n 80 --no-pager")
        return 0
    clear(state, "honkd")
    (state / "last-healthy").write_text(str(int(time.time())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
