# Pool-canary account classification, shared by teamclaude-pool-canary and
# teamclaude-relogin-reminder (hosts/cloudbox/configuration.nix) and exercised
# by hosts/cloudbox/test-teamclaude-healthy.sh. ONE copy, on purpose: the
# canary and the reminder once carried separate copies of this logic.
#
# Input:  a TeamClaude /teamclaude/status body.
# Output: one line, "HEALTHY SERVING".
#
#   SERVING = accounts that can take a request right now.
#   HEALTHY = SERVING + accounts that are merely SPENT right now and will come
#             back on their own (see "recovering" below). This is the number
#             the canary compares against its high-water mark, so it must only
#             drop for an account that needs a HUMAN.
#
# What still does NOT count toward HEALTHY (and therefore still pages):
#   - disabled accounts;
#   - status "error" -- a dead OAuth grant (refresh rejected: invalid_grant);
#   - PLAN-LESS accounts: status=active but all quota buckets unreported and no
#     5h consumption. A lapsed Max subscription keeps its OAuth grant and reads
#     active forever with no quota (johnnymo87, 2026-08-28..09-04). Workstation
#     PR #465. Unreported-ness alone is NOT enough -- a healthy account reports
#     a null unified7d for long stretches while its Fable and 5h buckets stay
#     live -- hence the three-way OR in reports_quota;
#   - a THROTTLED account with no quota readings (same plan-less signature);
#   - a THROTTLED account with no general-bucket reset still ahead (the
#     backstop -- see below).
#
# Why throttled counts as healthy (bead claude-failover-proxy-w1w). An account
# that spent its 5h (or 7d) allowance is the routine condition the router
# exists to absorb. On 2026-09-10 johnnymo872 sat at status=throttled, u5h=1.00
# from 13:15 to 16:15 EDT and the canary logged 39 consecutive "pool degraded"
# warnings for it; it cleared on its own when the window rolled. Nothing a
# human could do would have helped.
#
# The backstop. TeamClaude only reports "throttled" while its hold
# (rateLimitedUntil, capped at 1h, re-armed by each fresh upstream quota 429)
# is ahead, and it nulls a bucket's utilization and reset timestamp on the
# first status read after that reset passes (_clearExpiredQuotas). So a
# throttled account that still holds a 5h or 7d reset timestamp in the future
# is "spent, recovers at that time". One that is throttled with NO such reset
# -- every bucket it was spending has already reset, or never reported one --
# is being refused for a reason its quota does not explain, and that is worth
# a human's look. $grace only absorbs clock skew between TeamClaude's clock and
# ours; it is not a tolerance window.
#
# The global-outage guard is unchanged from PR #465: if the quota API stops
# reporting for EVERYONE, that is an upstream outage, not simultaneous
# cancellations, so SERVING falls back to the plain active count rather than
# declaring the whole fleet plan-less at 3am.

def reports_quota:
  ((.quota.unified7d) != null)
  or ((.quota.unified7dFable) != null)
  or (((.quota.unified5h) // 0) > 0);

(now * 1000) as $now_ms
| (15 * 60 * 1000) as $grace_ms
| [ (.accounts // [])[] | select(.disabled != true) ] as $enabled
| [ $enabled[] | select(.status == "active") ] as $active
| [ $active[] | select(reports_quota) ] as $reporting
| [ $enabled[]
    | select(.status == "throttled")
    | select(reports_quota)
    | select(
        ( [ .quota.unified5hReset, .quota.unified7dReset ]
          | map(select(type == "number")) | max ) as $reset
        | $reset != null and $reset > ($now_ms - $grace_ms)
      )
  ] as $recovering
# The guard keys on "nobody ENABLED reports quota", not "no active account
# reports": a spent (throttled) account reporting u5h=1.00 is proof the quota
# API is up, so it must not switch a plan-less active account back to counted.
| (if ([ $enabled[] | select(reports_quota) ] | length) == 0
   then ($active | length) else ($reporting | length) end) as $serving
| "\($serving + ($recovering | length)) \($serving)"
