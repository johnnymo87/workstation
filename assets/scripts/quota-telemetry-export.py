#!/usr/bin/env python3
"""Aggregate teamclaude's per-response usage ledger (and optionally cfp cash
events) into hourly rows and push them to the shared quota-telemetry repo
(beads workstation-ynoq.2, eng-agent-platform-ul4.26.9).

Inputs:
  --ledger      TEAMCLAUDE_USAGE_LOG JSONL (Max rows, one line per settled
                response; written by teamclaude >= johnnymo87/teamclaude#6).
  --cfp-events  Optional cfp events.jsonl (cash rows, backend <> 'max'; joins
                route->usage on requestId for model, aggregates cost_usd).
Output: <repo>/<host>/<ISO year>-W<ww>.jsonl, one row per
        (hour_utc, account, backend, model), sorted, only COMPLETE hours. Each
        run rewrites this host's files for the weeks it saw, so it is idempotent
        and never touches another host's files (no cross-host push conflicts).

Max row:  {host, hour_utc, account, model, input, cache_read, cache_write_5m,
           cache_write_1h, output, requests, split: true}
Cash row: {host, hour_utc, account: "", backend, model, input, cache_read,
           cache_write_5m, cache_write_1h: 0, output, requests, cost_usd}
`input` excludes cache (Anthropic usage semantics). Usage: see --help.
"""
import argparse, collections, datetime as dt, json, os, sqlite3, subprocess, sys

FIELDS = ("input", "cache_read", "cache_write_5m", "cache_write_1h", "output")


def _int_or_zero(val) -> int:
    if val is None or isinstance(val, bool):
        return 0
    try:
        return int(val)
    except (ValueError, TypeError):
        return 0


def _row_sort_key(r: dict):
    return (r["hour_utc"], r.get("account") or "", r.get("backend") or "max", r.get("model") or "")


def hour_of(ts: str | None) -> dt.datetime | None:
    if not isinstance(ts, str):
        return None
    try:
        t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.astimezone(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)


def hour_of_ms(ts) -> dt.datetime | None:
    if ts is None or isinstance(ts, bool) or not isinstance(ts, (int, float)):
        return None
    try:
        t = dt.datetime.fromtimestamp(ts / 1000.0, tz=dt.timezone.utc)
    except (ValueError, OverflowError, OSError):
        return None
    return t.replace(minute=0, second=0, microsecond=0)


def aggregate(lines, host: str, now: dt.datetime, since: dt.datetime):
    """Return {week_key: [rows]} for complete Max hours in [since, now's hour)."""
    cur_hour = now.astimezone(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    acc = collections.defaultdict(lambda: dict.fromkeys(FIELDS + ("requests",), 0))
    for line in lines:
        try:
            r = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(r, dict):
            continue
        h = hour_of(r.get("ts"))
        if h is None or h >= cur_hour or h < since:
            continue
        a = acc[(h, r.get("account"), r.get("model"))]
        cw = _int_or_zero(r.get("cache_write"))
        w5, w1 = _int_or_zero(r.get("cache_write_5m")), _int_or_zero(r.get("cache_write_1h"))
        if cw and not (w5 or w1):  # older/unsplit line: count it as 5m
            w5 = cw
        a["input"] += _int_or_zero(r.get("input"))
        a["cache_read"] += _int_or_zero(r.get("cache_read"))
        a["cache_write_5m"] += w5
        a["cache_write_1h"] += w1
        a["output"] += _int_or_zero(r.get("output"))
        a["requests"] += 1
    weeks = collections.defaultdict(list)
    for (h, account, model), v in acc.items():
        y, w, _ = h.isocalendar()
        weeks[f"{y}-W{w:02d}"].append({"host": host, "hour_utc": h.strftime("%Y-%m-%dT%H:00Z"),
                                       "account": account, "model": model, **v, "split": True})
    for rows in weeks.values():
        rows.sort(key=_row_sort_key)
    return weeks


def aggregate_cfp_events(lines, host: str, now: dt.datetime, since: dt.datetime):
    """Return ({week_key: [rows]}, first_hour) for complete cash hours (backend != 'max').

    Joins route->usage on requestId for model (order-independent), keeps only
    non-empty backend != 'max', and aggregates per (hour, backend, model) with
    account='' and summed cost_usd.
    """
    cur_hour = now.astimezone(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    route_since = since - dt.timedelta(hours=1)
    routes: dict[str, str] = {}
    usages: list[dict] = []
    first_hour: dt.datetime | None = None

    for line in lines:
        try:
            r = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(r, dict):
            continue
        ltype = r.get("type")
        if ltype in ("keepwarm", "boot"):
            continue
        h = hour_of_ms(r.get("ts"))
        if h is not None and (first_hour is None or h < first_hour):
            first_hour = h
        if ltype == "route":
            if h is not None and (h < route_since or h >= cur_hour):
                continue
            req_id = r.get("requestId")
            model = r.get("model")
            if isinstance(req_id, str) and req_id and isinstance(model, str) and model:
                routes[req_id] = model
        elif ltype == "usage":
            if h is None or h < since or h >= cur_hour:
                continue
            backend = r.get("backend")
            if not isinstance(backend, str) or not backend or backend == "max":
                continue
            usages.append(r)

    acc = collections.defaultdict(lambda: {
        "input": 0, "cache_read": 0, "cache_write_5m": 0, "cache_write_1h": 0,
        "output": 0, "requests": 0, "cost_usd": 0.0, "has_cost": False,
    })
    for r in usages:
        h = hour_of_ms(r.get("ts"))
        if h is None or h >= cur_hour or h < since:
            continue
        req_id = r.get("requestId")
        model = routes.get(req_id) if isinstance(req_id, str) else None
        if not model:
            m = r.get("model")
            model = m if isinstance(m, str) and m else None
        if not model:
            continue
        backend = r["backend"]
        raw_u = r.get("usage")
        u = raw_u if isinstance(raw_u, dict) else {}
        a = acc[(h, backend, model)]
        a["input"] += _int_or_zero(u.get("input"))
        a["output"] += _int_or_zero(u.get("output"))
        a["cache_read"] += _int_or_zero(u.get("cacheRead"))
        a["cache_write_5m"] += _int_or_zero(u.get("cacheWrite"))
        a["requests"] += 1
        cost = r.get("cost")
        if isinstance(cost, (int, float)) and not isinstance(cost, bool):
            a["cost_usd"] += float(cost)
            a["has_cost"] = True

    weeks = collections.defaultdict(list)
    for (h, backend, model), v in acc.items():
        y, w, _ = h.isocalendar()
        weeks[f"{y}-W{w:02d}"].append({
            "host": host,
            "hour_utc": h.strftime("%Y-%m-%dT%H:00Z"),
            "account": "",
            "backend": backend,
            "model": model,
            "input": v["input"],
            "cache_read": v["cache_read"],
            "cache_write_5m": v["cache_write_5m"],
            "cache_write_1h": 0,
            "output": v["output"],
            "requests": v["requests"],
            "cost_usd": round(v["cost_usd"], 6) if v["has_cost"] else None,
        })
    for rows in weeks.values():
        rows.sort(key=_row_sort_key)
    return weeks, first_hour


def aggregate_goose_vertex_gemini(
    db_path: str,
    host: str,
    now: dt.datetime,
    since: dt.datetime,
    cfp_cash_weeks: dict[str, list[dict]],
):
    """Return ({week_key: [rows]}, first_hour) for Mac goose Neon spend that bypassed cfp agy.

    cfp's Gemini handler emits `usage` events for agy 2xx turns only; Vertex fallback
    turns (after the agy budget fills or on agy errors) have no cfp usage event on hosts
    without an aigateway. For each complete hour, any excess of goose's `usage_ledger`
    Neon cost over cfp's `agy` Neon cost is emitted as a `vertex-gemini` row so the
    fleet cap sees both legs without double-counting agy turns.
    """
    cur_hour = now.astimezone(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    since_s = int(since.timestamp())
    cur_s = int(cur_hour.timestamp())

    agy_by_hour: dict[tuple[str, str], dict] = {}
    for rows in cfp_cash_weeks.values():
        for r in rows:
            if r.get("backend") == "agy":
                key = (r["hour_utc"], r.get("model") or "")
                agy_by_hour[key] = r

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    first_hour: dt.datetime | None = None
    acc = collections.defaultdict(lambda: {
        "input": 0, "cache_read": 0, "cache_write_5m": 0,
        "output": 0, "requests": 0, "cost_usd": 0.0,
    })
    try:
        min_row = con.execute(
            "SELECT MIN(created_timestamp) FROM usage_ledger WHERE model LIKE '%gemini-4-neon%'"
        ).fetchone()
        if min_row and min_row[0] is not None:
            first_hour = dt.datetime.fromtimestamp(int(min_row[0]), tz=dt.timezone.utc).replace(
                minute=0, second=0, microsecond=0
            )
        rows = con.execute(
            "SELECT created_timestamp, model, input_tokens, output_tokens, "
            "cache_read_tokens, cache_write_tokens, cost "
            "FROM usage_ledger "
            "WHERE created_timestamp >= ? AND created_timestamp < ? "
            "AND model LIKE '%gemini-4-neon%' AND cost IS NOT NULL",
            (since_s, cur_s),
        ).fetchall()
        for ts_s, model, inp, outp, cread, cwrite, cost in rows:
            if not isinstance(model, str) or not model:
                continue
            try:
                c = float(cost)
            except (ValueError, TypeError):
                continue
            if c <= 0:
                continue
            h = dt.datetime.fromtimestamp(int(ts_s), tz=dt.timezone.utc).replace(
                minute=0, second=0, microsecond=0
            )
            a = acc[(h, model)]
            a["input"] += _int_or_zero(inp)
            a["output"] += _int_or_zero(outp)
            a["cache_read"] += _int_or_zero(cread)
            a["cache_write_5m"] += _int_or_zero(cwrite)
            a["requests"] += 1
            a["cost_usd"] += c
    finally:
        con.close()

    weeks = collections.defaultdict(list)
    for (h, model), v in acc.items():
        h_str = h.strftime("%Y-%m-%dT%H:00Z")
        agy = agy_by_hour.get((h_str, model))
        agy_cost = float(agy.get("cost_usd") or 0.0) if agy else 0.0
        delta_cost = v["cost_usd"] - agy_cost
        if delta_cost <= 0.001:
            continue
        agy_reqs = _int_or_zero(agy.get("requests")) if agy else 0
        y, w, _ = h.isocalendar()
        weeks[f"{y}-W{w:02d}"].append({
            "host": host,
            "hour_utc": h_str,
            "account": "",
            "backend": "vertex-gemini",
            "model": model,
            "input": max(0, v["input"] - (_int_or_zero(agy.get("input")) if agy else 0)),
            "cache_read": max(0, v["cache_read"] - (_int_or_zero(agy.get("cache_read")) if agy else 0)),
            "cache_write_5m": max(0, v["cache_write_5m"] - (_int_or_zero(agy.get("cache_write_5m")) if agy else 0)),
            "cache_write_1h": 0,
            "output": max(0, v["output"] - (_int_or_zero(agy.get("output")) if agy else 0)),
            "requests": max(1, v["requests"] - agy_reqs),
            "cost_usd": round(delta_cost, 6),
        })
    for w_rows in weeks.values():
        w_rows.sort(key=_row_sort_key)
    return weeks, first_hour


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", repo, *args], check=check, capture_output=True, text=True)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    p.add_argument("--ledger", default=os.environ.get("TEAMCLAUDE_USAGE_LOG",
                   os.path.expanduser("~/.local/state/teamclaude/usage.jsonl")))
    p.add_argument("--cfp-events", default=None,
                   help="optional cfp events.jsonl for cash rows (backend <> 'max')")
    p.add_argument("--goose-db", default=None,
                   help="optional goose sessions.db for Vertex Gemini fallback rows not in cfp events")
    p.add_argument("--repo", default=os.path.expanduser("~/.local/state/quota-telemetry/repo"))
    p.add_argument("--remote", default="git@github.com:johnnymo87/quota-telemetry.git")
    p.add_argument("--host", default=os.uname().nodename)
    p.add_argument("--days", type=int, default=8, help="re-export weeks touched in the last N days")
    p.add_argument("--no-push", action="store_true")
    a = p.parse_args(argv)

    has_ledger = bool(a.ledger and os.path.exists(a.ledger))
    has_cfp = bool(a.cfp_events and os.path.exists(a.cfp_events))
    has_goose = bool(a.goose_db and os.path.exists(a.goose_db))
    if not has_ledger and not has_cfp and not has_goose:
        msg = f"no ledger at {a.ledger}"
        if a.cfp_events:
            msg += f" and no cfp events at {a.cfp_events}"
        if a.goose_db:
            msg += f" and no goose db at {a.goose_db}"
        print(f"{msg}; nothing to export")
        return 0
    if not os.path.isdir(os.path.join(a.repo, ".git")):
        os.makedirs(os.path.dirname(a.repo), exist_ok=True)
        subprocess.run(["git", "clone", "-q", a.remote, a.repo], check=True)
    if not a.no_push:
        # Output is regenerable from the ledger, so on any pull trouble take
        # upstream as-is rather than leave a half-done rebase for every later run.
        if git(a.repo, "pull", "-q", "--rebase", check=False).returncode != 0:
            git(a.repo, "rebase", "--abort", check=False)
            git(a.repo, "fetch", "-q", check=False)
            git(a.repo, "reset", "-q", "--hard", "@{u}", check=False)

    now = dt.datetime.now(dt.timezone.utc)
    since = now - dt.timedelta(days=a.days)
    # Re-export whole weeks: start at the Monday of `since`'s ISO week.
    y, w, _ = since.isocalendar()
    since = dt.datetime.fromisocalendar(y, w, 1).replace(tzinfo=dt.timezone.utc)

    first_max = None
    max_weeks: dict[str, list[dict]] = {}
    if has_ledger:
        with open(a.ledger, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    first_max = hour_of(json.loads(line).get("ts"))
                except (ValueError, TypeError, AttributeError):
                    continue
                if first_max:
                    break
            f.seek(0)
            max_weeks = aggregate(f, a.host, now, since)

    first_cash = None
    cash_weeks: dict[str, list[dict]] = {}
    if has_cfp:
        with open(a.cfp_events, encoding="utf-8", errors="replace") as f:
            cash_weeks, first_cash = aggregate_cfp_events(f, a.host, now, since)

    if has_goose:
        vg_weeks, first_vg = aggregate_goose_vertex_gemini(a.goose_db, a.host, now, since, cash_weeks)
        for key, vg_rows in vg_weeks.items():
            cash_weeks.setdefault(key, []).extend(vg_rows)
            cash_weeks[key].sort(key=_row_sort_key)
        if first_vg is not None and (first_cash is None or first_vg < first_cash):
            first_cash = first_vg

    all_weeks = sorted(set(max_weeks) | set(cash_weeks))
    total_exported = 0
    os.makedirs(os.path.join(a.repo, a.host), exist_ok=True)
    for key in all_weeks:
        path = os.path.join(a.repo, a.host, f"{key}.jsonl")
        new_max = max_weeks.get(key, [])
        new_cash = cash_weeks.get(key, [])
        kept_max: list[dict] = []
        kept_cash: list[dict] = []
        # A source log that was moved or truncated must not erase hours already
        # exported: keep committed rows older than each source's first line.
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                existing = [json.loads(l) for l in f if l.strip()]
            existing_max = [r for r in existing if (r.get("backend") or "max") == "max"]
            existing_cash = [r for r in existing if (r.get("backend") or "max") != "max"]
            if first_max is not None:
                cutoff_max = first_max.strftime("%Y-%m-%dT%H:00Z")
                kept_max = [r for r in existing_max if r.get("hour_utc", "") < cutoff_max]
            else:
                kept_max = existing_max
            if first_cash is not None:
                cutoff_cash = first_cash.strftime("%Y-%m-%dT%H:00Z")
                kept_cash = [r for r in existing_cash if r.get("hour_utc", "") < cutoff_cash]
            else:
                kept_cash = existing_cash
        rows = sorted(kept_max + new_max + kept_cash + new_cash, key=_row_sort_key)
        total_exported += len(rows)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, sort_keys=True) + "\n")
        os.replace(tmp, path)
    # Watermark: hours after this are MISSING (exporter down), not zero usage.
    with open(os.path.join(a.repo, a.host, "_exported_through.json"), "w", encoding="utf-8") as f:
        last = now.replace(minute=0, second=0, microsecond=0) - dt.timedelta(hours=1)
        f.write(json.dumps({"host": a.host, "hour_utc": last.strftime("%Y-%m-%dT%H:00Z")}) + "\n")
    git(a.repo, "add", "-A", a.host)
    if git(a.repo, "diff", "--cached", "--quiet", check=False).returncode != 0:
        # Unsigned: regenerable data, and an unattended job may not reach the
        # signing key (no agent/tty under launchd or systemd).
        git(a.repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", f"{a.host}: hourly usage through {now:%Y-%m-%dT%H:00Z}")
    rl = git(a.repo, "rev-list", "--count", "@{u}..HEAD", check=False)
    ahead = rl.stdout.strip() if rl.returncode == 0 else "unknown"  # no upstream yet: push
    if not a.no_push and ahead != "0":
        r = git(a.repo, "push", "-q", "-u", "origin", "HEAD", check=False)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            return 1
    print(f"exported {total_exported} rows across {len(all_weeks)} week(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
