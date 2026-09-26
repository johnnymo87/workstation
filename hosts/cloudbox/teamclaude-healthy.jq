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
#   - a THROTTLED account whose quota resets have ALL passed (the backstop --
#     see below).
#
# Why throttled counts as healthy (bead claude-failover-proxy-w1w). An account
# that spent its 5h (or 7d) allowance is the routine condition the router
# exists to absorb. On 2026-09-10 johnnymo872 sat at status=throttled, u5h=1.00
# from 13:15 to 16:15 EDT and the canary logged 39 consecutive "pool degraded"
# warnings for it; it cleared on its own when the window rolled. Nothing a
# human could do would have helped.
#
# The backstop: throttled well past its reset. A throttled account counts as
# recovering unless every reset timestamp it reports (5h, 7d, Fable 7d) is
# more than $grace in the past -- i.e. its buckets should have refilled and it
# is still being refused, which no quota explains.
#
# How much that can catch, stated plainly so its silence is not over-read:
# against CURRENT TeamClaude, very little. TeamClaude only reports
# "throttled" while its hold (rateLimitedUntil, capped at 1h) is ahead; the
# hold is re-armed only by a fresh upstream quota 429, which also refreshes the
# utilization and reset from the same response headers; and it nulls a
# bucket's utilization AND reset together on the first status read after that
# reset passes (_clearExpiredQuotas). So a passed reset normally never reaches
# us. The backstop is a guard against TeamClaude drifting from that contract,
# not a detector of upstream anomalies: an account upstream keeps rejecting on
# its 5h bucket after that bucket's declared reset still reads healthy for as
# long as it reports ANY reset ahead -- up to a week, via its 7d reset.
#
# A throttled account reporting NO reset timestamp at all is trusted, on
# purpose. That is the normal shape of the up-to-1h tail after a 5h reset
# passes (bucket nulled, hold not yet expired), and treating it as broken
# would page, after the 2-pass dampening, for an account minutes from
# recovering -- the exact class this filter exists to stop. A throttled
# account with no quota at all is still excluded, by reports_quota.
#
# $grace only absorbs clock skew between TeamClaude's clock and ours.

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
        ( [ .quota.unified5hReset, .quota.unified7dReset, .quota.unified7dFableReset ]
          | map(select(type == "number")) | max ) as $reset
        | $reset == null or $reset > ($now_ms - $grace_ms)
      )
  ] as $recovering
# The guard keys on "nobody ENABLED reports quota", not "no active account
# reports": a spent (throttled) account reporting u5h=1.00 is proof the quota
# API is up, so it must not switch a plan-less active account back to counted.
| (if ([ $enabled[] | select(reports_quota) ] | length) == 0
   then ($active | length) else ($reporting | length) end) as $serving
| "\($serving + ($recovering | length)) \($serving)"
