#!/usr/bin/env python3
"""Aggregate teamclaude's per-response usage ledger into hourly rows and push
them to the shared quota-telemetry repo (bead workstation-ynoq.2).

Input:  TEAMCLAUDE_USAGE_LOG JSONL (one line per settled response; written by
        teamclaude >= johnnymo87/teamclaude#6).
Output: <repo>/<host>/<ISO year>-W<ww>.jsonl, one row per
        (hour_utc, account, model), sorted, only COMPLETE hours. Each run
        rewrites this host's files for the weeks it saw, so it is idempotent
        and never touches another host's files (no cross-host push conflicts).

Row: {host, hour_utc, account, model, input, cache_read, cache_write_5m,
      cache_write_1h, output, requests, split: true}
`input` excludes cache (Anthropic usage semantics). Usage: see --help.
"""
import argparse, collections, datetime as dt, json, os, subprocess, sys

FIELDS = ("input", "cache_read", "cache_write_5m", "cache_write_1h", "output")


def hour_of(ts: str) -> dt.datetime | None:
    try:
        t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    return t.astimezone(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)


def aggregate(lines, host: str, now: dt.datetime, since: dt.datetime):
    """Return {week_key: [rows]} for complete hours in [since, now's hour)."""
    cur_hour = now.astimezone(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    acc = collections.defaultdict(lambda: dict.fromkeys(FIELDS + ("requests",), 0))
    for line in lines:
        try:
            r = json.loads(line)
        except (ValueError, TypeError):
            continue
        h = hour_of(r.get("ts"))
        if h is None or h >= cur_hour or h < since:
            continue
        a = acc[(h, r.get("account"), r.get("model"))]
        cw = r.get("cache_write") or 0
        w5, w1 = r.get("cache_write_5m") or 0, r.get("cache_write_1h") or 0
        if cw and not (w5 or w1):  # older/unsplit line: count it as 5m
            w5 = cw
        a["input"] += r.get("input") or 0
        a["cache_read"] += r.get("cache_read") or 0
        a["cache_write_5m"] += w5
        a["cache_write_1h"] += w1
        a["output"] += r.get("output") or 0
        a["requests"] += 1
    weeks = collections.defaultdict(list)
    for (h, account, model), v in acc.items():
        y, w, _ = h.isocalendar()
        weeks[f"{y}-W{w:02d}"].append({"host": host, "hour_utc": h.strftime("%Y-%m-%dT%H:00Z"),
                                       "account": account, "model": model, **v, "split": True})
    for rows in weeks.values():
        rows.sort(key=lambda r: (r["hour_utc"], r["account"] or "", r["model"] or ""))
    return weeks


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", repo, *args], check=check, capture_output=True, text=True)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    p.add_argument("--ledger", default=os.environ.get("TEAMCLAUDE_USAGE_LOG",
                   os.path.expanduser("~/.local/state/teamclaude/usage.jsonl")))
    p.add_argument("--repo", default=os.path.expanduser("~/.local/state/quota-telemetry/repo"))
    p.add_argument("--remote", default="git@github.com:johnnymo87/quota-telemetry.git")
    p.add_argument("--host", default=os.uname().nodename)
    p.add_argument("--days", type=int, default=8, help="re-export weeks touched in the last N days")
    p.add_argument("--no-push", action="store_true")
    a = p.parse_args(argv)

    if not os.path.exists(a.ledger):
        print(f"no ledger at {a.ledger}; nothing to export")
        return 0
    if not os.path.isdir(os.path.join(a.repo, ".git")):
        os.makedirs(os.path.dirname(a.repo), exist_ok=True)
        subprocess.run(["git", "clone", "-q", a.remote, a.repo], check=True)
    if not a.no_push:
        git(a.repo, "pull", "-q", "--rebase", check=False)

    now = dt.datetime.now(dt.timezone.utc)
    since = now - dt.timedelta(days=a.days)
    # Re-export whole weeks: start at the Monday of `since`'s ISO week.
    y, w, _ = since.isocalendar()
    since = dt.datetime.fromisocalendar(y, w, 1).replace(tzinfo=dt.timezone.utc)
    with open(a.ledger, encoding="utf-8", errors="replace") as f:
        weeks = aggregate(f, a.host, now, since)

    os.makedirs(os.path.join(a.repo, a.host), exist_ok=True)
    for key, rows in weeks.items():
        path = os.path.join(a.repo, a.host, f"{key}.jsonl")
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, sort_keys=True) + "\n")
        os.replace(tmp, path)
    git(a.repo, "add", "-A", a.host)
    if git(a.repo, "diff", "--cached", "--quiet", check=False).returncode == 0:
        print("no change")
        return 0
    git(a.repo, "commit", "-q", "-m", f"{a.host}: hourly usage through {now:%Y-%m-%dT%H:00Z}")
    if not a.no_push:
        r = git(a.repo, "push", "-q", check=False)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            return 1
    print(f"exported {sum(map(len, weeks.values()))} rows across {len(weeks)} week(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
