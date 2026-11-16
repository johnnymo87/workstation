#!/usr/bin/env python3
"""Watch aigateway's ledger for Gemini sessions stuck at zero prompt-cache reads.

Complements the opencode `cache-miss-breaker` plugin (workstation-ke9f.1):
- covers top-level opencode sessions and non-opencode clients (goose), where
  the subagent-only breaker deliberately does not act;
- reports whether `request_prefix_hash` stayed constant across the stuck steps
  (pointing at Vertex) or changed between steps (pointing at client-side prefix
  churn), using the columns added in the monorepo gateway PR (mono#5865,
  workstation-ke9f.2).

Exits 0 cleanly before those columns are migrated so the timer can ship ahead
of the monorepo gateway deploy.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import time

TRIP_STEPS = 10
MIN_CONTEXT = 50_000
LOOKBACK_HOURS = 6
ACTIVE_WINDOW_SEC = 1800

SCHEMA_SQL = (
    "SELECT count(*) FROM information_schema.columns "
    "WHERE table_name = 'gateway_request_log' AND column_name = 'request_prefix_hash';"
)

ROWS_SQL = f"""
SELECT
  id,
  extract(epoch FROM request_started_at)::bigint,
  model,
  COALESCE(total_context_tokens, 0),
  COALESCE(cache_read_tokens, -1),
  COALESCE(total_dollars, 0),
  COALESCE(client_session_id, ''),
  COALESCE(parent_session_id, ''),
  COALESCE(request_prefix_hash, ''),
  COALESCE(first_content_hash, '')
FROM gateway_request_log
WHERE request_started_at > now() - interval '{LOOKBACK_HOURS} hours'
  AND vertex_path LIKE '%/publishers/google/%'
  AND http_status = 200
  AND total_context_tokens IS NOT NULL
ORDER BY id ASC;
""".strip()


@dataclass
class Streak:
    start_id: int = 0
    max_id: int = 0
    count: int = 0
    last_epoch: int = 0
    last_ctx: int = 0
    dollars: float = 0.0
    model: str = ""
    parent_id: str = ""
    prefixes: list[str] = field(default_factory=list)


def run_psql(sql: str) -> tuple[int, str, str]:
    override = os.environ.get("ACM_PSQL_CMD")
    if override:
        cmd = [override, sql]
    else:
        docker = os.environ.get("ACM_DOCKER_BIN", "docker")
        cmd = [
            docker, "exec", "dev-postgres-1",
            "psql", "-U", "aigateway", "-d", "aigateway",
            "-v", "ON_ERROR_STOP=1", "-AtF", "\t", "-c", sql,
        ]
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, timeout=15, check=False)
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "psql command timed out after 15s"
    except OSError as exc:
        return 127, "", str(exc)


def send_alert(alert_cmd: str, state_file: Path, sig: str, text: str, ttl: int = 900, max_interval: int = 14400) -> None:
    if not alert_cmd:
        print(f"ALERT ({sig}): {text}")
        return
    cmd = [alert_cmd, str(state_file), sig, text, str(ttl), str(max_interval)]
    subprocess.run(cmd, check=False)


def record_psql_failure(state_dir: Path, alert_cmd: str, rc: int, err: str) -> None:
    fail_count_file = state_dir / "psql-fail-count"
    fail_alert_file = state_dir / "alert-psql-failed.state"
    fails = 1
    if fail_count_file.exists():
        try:
            fails = int(fail_count_file.read_text(encoding="utf-8").strip()) + 1
        except ValueError:
            fails = 1
    fail_count_file.write_text(f"{fails}\n", encoding="utf-8")
    if fails >= 2:
        send_alert(
            alert_cmd,
            fail_alert_file,
            "psql-failed",
            f"aigateway-cache-miss-watch failed to query dev-postgres-1 ({fails} consecutive ticks): {err.strip() or f'exit {rc}'}. "
            "Check: docker ps | grep dev-postgres-1; journalctl --user -u aigateway-cache-miss-watch -n 50",
            ttl=900,
        )


def prefix_diagnosis(prefixes: list[str]) -> str:
    non_empty = [p for p in prefixes if p]
    if not non_empty:
        return "prefix hash unavailable (empty/unparsed body)"
    distinct = list(dict.fromkeys(non_empty))
    if len(distinct) == 1:
        return f"prefix stable ({distinct[0]} across all {len(non_empty)} steps -> likely Vertex-side)"
    transitions = sum(1 for a, b in zip(non_empty, non_empty[1:]) if a != b)
    return f"prefix changed {transitions}x ({len(distinct)} distinct hashes -> client-side prefix churn)"


def main() -> int:
    flag = Path(os.environ.get("ACM_FLAG_FILE", "/var/lib/aigateway/enabled"))
    if not flag.exists():
        return 0

    state_dir = Path(
        os.environ.get(
            "ACM_STATE_DIR",
            str(Path.home() / ".local" / "state" / "aigateway-cache-miss-watch"),
        )
    )
    state_dir.mkdir(parents=True, exist_ok=True)
    alert_cmd = os.environ.get("ACM_ALERT_CMD", "")
    now = int(os.environ.get("ACM_NOW_EPOCH") or time.time())

    fail_count_file = state_dir / "psql-fail-count"
    fail_alert_file = state_dir / "alert-psql-failed.state"
    partial_alert_file = state_dir / "alert-partial-deploy.state"

    rc, out, err = run_psql(SCHEMA_SQL)
    if rc != 0:
        record_psql_failure(state_dir, alert_cmd, rc, err)
        return 0

    if out.strip() != "1":
        fail_count_file.unlink(missing_ok=True)
        fail_alert_file.unlink(missing_ok=True)
        print("aigateway-cache-miss-watch: fingerprint columns not migrated yet; skipping")
        return 0

    rc, rows_out, err = run_psql(ROWS_SQL)
    if rc != 0:
        record_psql_failure(state_dir, alert_cmd, rc, err)
        return 0

    fail_count_file.unlink(missing_ok=True)
    fail_alert_file.unlink(missing_ok=True)

    streaks: dict[str, Streak] = {}
    labels: dict[str, str] = {}
    total_rows = 0
    keyed_rows = 0

    for line in rows_out.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 10:
            continue
        total_rows += 1
        row_id = int(parts[0])
        epoch = int(parts[1])
        model = parts[2]
        ctx = int(parts[3])
        cache_read = int(parts[4])
        dollars = float(parts[5])
        session_id, parent_id, prefix_hash, first_hash = parts[6], parts[7], parts[8], parts[9]

        if session_id:
            key = session_id
            labels[key] = session_id
            keyed_rows += 1
        elif first_hash:
            key = f"first:{first_hash}"
            labels[key] = f"first_content={first_hash}"
            keyed_rows += 1
        else:
            continue

        if ctx < MIN_CONTEXT:
            continue
        if cache_read > 0:
            streaks.pop(key, None)
            continue
        if cache_read != 0:
            continue

        s = streaks.get(key)
        if s is None:
            s = Streak(start_id=row_id)
            streaks[key] = s
        s.max_id = row_id
        s.count += 1
        s.last_epoch = epoch
        s.last_ctx = ctx
        s.dollars += dollars
        s.model = model
        if parent_id:
            s.parent_id = parent_id
        s.prefixes.append(prefix_hash)

    # Guard against partial deploy (migration applied, old server.jar writing NULLs).
    if total_rows >= 20 and keyed_rows == 0:
        send_alert(
            alert_cmd,
            partial_alert_file,
            "partial-deploy",
            f"aigateway-cache-miss-watch saw {total_rows} Gemini rows in the last {LOOKBACK_HOURS}h with NULL session/fingerprint columns. "
            "migrate.jar ran, but server.jar appears un-upgraded.",
            ttl=900,
        )
    else:
        partial_alert_file.unlink(missing_ok=True)

    active_digests: set[str] = set()
    for key, s in streaks.items():
        if s.count < TRIP_STEPS or (now - s.last_epoch) > ACTIVE_WINDOW_SEC:
            continue
        digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
        active_digests.add(digest)
        state_file = state_dir / f"episode-{digest}.state"
        seen_file = state_dir / f"episode-{digest}.seen"

        # If the session has stopped advancing (e.g. M1 stopped the subagent or
        # the turn ended) and we already alerted for this exact max_id, do not
        # re-alert while waiting for ACTIVE_WINDOW_SEC to age out.
        prev_episode, prev_max = None, None
        if seen_file.exists():
            try:
                ep_s, max_s = seen_file.read_text(encoding="utf-8").strip().split("\t", 1)
                prev_episode, prev_max = int(ep_s), int(max_s)
            except ValueError:
                pass
        if prev_episode == s.start_id and prev_max == s.max_id and state_file.exists():
            continue

        # New episode in the same session (after a cache hit reset): clear prior
        # backoff state so the fresh episode alerts immediately.
        if prev_episode is not None and prev_episode != s.start_id:
            state_file.unlink(missing_ok=True)

        scope = (
            f"subagent of {s.parent_id} (opencode breaker stops at 10 after serve restart)"
            if s.parent_id
            else "top-level / non-opencode session (NOT covered by subagent breaker)"
        )
        verdict = prefix_diagnosis(s.prefixes)
        text = (
            f"Gemini prompt-cache miss streak on cloudbox: {labels[key]} ({s.model}, {scope}) "
            f"had {s.count} consecutive steps >=50K ctx with cache_read=0 "
            f"(latest ~{round(s.last_ctx / 1000)}K ctx, ${s.dollars:.2f} in streak). "
            f"Diagnosis: {verdict}."
        )
        send_alert(alert_cmd, state_file, key, text, ttl=900, max_interval=14400)
        seen_file.write_text(f"{s.start_id}\t{s.max_id}\n", encoding="utf-8")

    # Clear state for sessions whose streak ended (cache hit or aged past window),
    # so a future episode starts fresh with immediate delivery + clean backoff.
    for p in list(state_dir.glob("episode-*.state")) + list(state_dir.glob("episode-*.seen")):
        stem = p.name.split(".", 1)[0].removeprefix("episode-")
        if stem not in active_digests:
            p.unlink(missing_ok=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
