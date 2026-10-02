# Renders codex-lb's /api/accounts (+ optional /api/usage/summary) as a
# teamclaude-status-shaped readout. Inputs:
#   $acc      slurped /api/accounts (array of exactly one document)
#   $summary  slurped /api/usage/summary, or [] when it could not be fetched
#   $sumerr   why the summary is missing ("" when present)
#   $now      epoch seconds
#   $port     the port we talked to
#
# Shape validation is strict only where an unvalidated container would be
# iterated (the `.accounts[]` -> object trap astra-probe hit). Individual
# fields are type-checked at use and degrade to "no data" / "?" rather than
# printing `null` -- a display tool should show what it can.

def num:  if type == "number" then . else null end;
def str:  if type == "string" then . else null end;
def obj:  if type == "object" then . else {} end;
def rep($s; $n): if $n <= 0 then "" else $s * $n end;

# ISO-8601 (codex-lb emits both "...Z" and "....063686Z") or epoch -> epoch.
def ts:
  if type == "number" then .
  elif type == "string" then
    (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch null)
  else null end;

def dur:
  (. | floor) as $s
  | ($s / 86400 | floor) as $d | (($s % 86400) / 3600 | floor) as $h
  | (($s % 3600) / 60 | floor) as $m
  | if $d > 0 then "\($d)d\($h)h"
    elif $h > 0 then "\($h)h\($m)m"
    elif $m > 0 then "\($m)m"
    else "<1m" end;

def human:
  if . >= 1000000 then "\((. / 100000 | round) / 10)m"
  elif . >= 1000 then "\((. / 100 | round) / 10)k"
  else tostring end;

def bar($u): ($u * 18 / 100 | round) as $n
  | "[" + rep("█"; $n) + rep("░"; 18 - $n) + "]";

def resetpart($r):
  ($r | ts) as $t
  | if $t == null then ""
    elif $t > $now then ", reset \($t - $now | dur)"
    else ", reset passed \($now - $t | dur) ago (stale)" end;

# $rem is codex-lb's REMAINING percent; we print USED, as teamclaude does.
def window($label; $rem; $reset):
  ($rem | num) as $r
  | ($label + rep(" "; 9 - ($label | length))) as $l
  | if $r == null then "  \($l)no data"
    else ([0, ([100, 100 - $r] | min)] | max) as $u
      | "  \($l)\(bar($u)) \($u | round)% used\(resetpart($reset))"
    end;

def account_block:
  obj as $a
  | (($a.alias | str) // ($a.displayName | str) // ($a.email | str)
     // ($a.accountId | str) // "<unnamed>") as $name
  | (($a.status | str) // "?") as $status
  | ($a.usage | obj) as $u
  | ($a.requestUsage | obj) as $ru
  | ($a.lastRefreshAt | ts) as $refresh
  | [ "  \($name) (\(($a.planType | str) // "?")) \($status)"
        + (if $status == "active" then "" else " !!" end),
      window("5h"; $u.primaryRemainingPercent; $a.resetAtPrimary),
      window("Weekly"; $u.secondaryRemainingPercent; $a.resetAtSecondary),
      (if ($u.monthlyRemainingPercent | num) != null
       then window("Monthly"; $u.monthlyRemainingPercent; $a.resetAtMonthly)
       else empty end),
      # lastRefreshAt is the OAuth TOKEN refresh, which codex-lb does every
      # 8 days (TOKEN_REFRESH_INTERVAL_DAYS) -- NOT usage freshness, which the
      # no-auth API does not expose (usage_refreshed_at is exclude=True).
      # Past 9 days the refresh is overdue, i.e. auth is stuck.
      "  Token    " + (
        if $refresh == null then "never refreshed"
        else "refreshed \([0, $now - $refresh] | max | dur) ago"
          + (if $now - $refresh > 9 * 86400
             then " (OVERDUE: codex-lb refreshes every 8d; auth is stuck)"
             else "" end)
        end),
      (if ($ru.requestCount | num) != null then
         "  Lifetime \($ru.requestCount) req"
         + (if ($ru.totalTokens | num) != null then ", \($ru.totalTokens | human) tok" else "" end)
         + (if ($ru.totalCostUsd | num) != null
            then ", $\(($ru.totalCostUsd * 100 | round) / 100)" else "" end)
       else empty end),
      (if ($a.deactivationReason | str) != null
       then "  Reason   \($a.deactivationReason)" else empty end),
      ""
    ]
  | join("\n");

def fleet:
  if ($summary | length) != 1 or ($summary[0] | type) != "object" then
    "Fleet    unavailable (\(if $sumerr == "" then "unrecognized /api/usage/summary response" else $sumerr end))"
  else
    $summary[0] as $s
    | ($s.primaryWindow | obj) as $p
    | ($s.secondaryWindow | obj) as $w
    | ($s.monthlyWindow | obj) as $mo
    | ($s.metrics | obj) as $m
    | [ "Fleet (capacity-weighted mean across accounts; can look healthy while one account is dead)",
        window("5h"; $p.remainingPercent; $p.resetAt),
        window("Weekly"; $w.remainingPercent; $w.resetAt),
        (if ($mo.remainingPercent | num) != null
         then window("Monthly"; $mo.remainingPercent; $mo.resetAt) else empty end),
        (if ($m.requests7d | num) != null then
           "  7d       \($m.requests7d) req"
           + (if ($m.errorRate7d | num) != null
              then ", \(($m.errorRate7d * 1000 | round) / 10)% errors" else "" end)
           + (if ($m.topError | str) != null then ", top: \($m.topError)" else "" end)
         else empty end)
      ]
    | join("\n")
  end;

if ($acc | length) != 1 or ($acc[0] | type) != "object"
   or ($acc[0].accounts | type) != "array" then
  error("unrecognized /api/accounts response (expected an object with an `accounts` array)")
else
  $acc[0].accounts as $accts
  | ([$accts[] | select(type == "object" and .status == "active")] | length) as $active
  | "codex-lb status",
    "Server   127.0.0.1:\($port), \($accts | length) account\(if ($accts | length) == 1 then "" else "s" end), \($active) active",
    "",
    (if ($accts | length) == 0 then "  no accounts configured (log one in via the codex-lb dashboard)\n"
     else ($accts[] | account_block) end),
    fleet
end
