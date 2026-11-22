# Claude Max quota budget: devbox + cloudbox (analysis, 2026-11-23)

Bead: `workstation-ciyl`. This is analysis only; nothing here has been built.

## Bottom line

- **The pool is oversubscribed.** devbox and cloudbox share the same five
  Claude Max 20x accounts through teamclaude:

  | Account | Next weekly reset |
  |---|---|
  | johnnymo87 | 11-27 04:00Z |
  | johnnymo872 | 11-25 12:00Z |
  | johnnymo873 | 11-29 23:00Z |
  | johnnymo874 | 11-23 05:00Z |
  | jonathan.mohrbacher | 11-27 23:00Z |

  - In the 7 days to 11-22 the two hosts consumed about **7.0 account-weeks**
    of quota, and the pool supplies 5.0. That is about **4.2% of one account
    per hour**, against a sustainable 2.98%/h.
  - At the weekday rate (about 1.25 account-weeks a day), a fully fresh pool
    lasts about **4 days**.
  - 7.0 is a floor. The 11-22 freeze held back demand.
- **We can't yet say whether every week is like this.** devbox's own Max
  spend has held steady for 4 weeks:

  | Week ending 11-22 17:00Z | wk −4 | wk −3 | wk −2 | wk −1 |
  |---|---|---|---|---|
  | devbox list $ | 5,516 | 4,645 | 3,905 | 5,160 |

  Earlier weeks did not freeze, as far as we know. So either cloudbox was
  lighter then, or headroom carried over from the previous cycle covered it.
  In this window, at least 2.1 of the 7.0 account-weeks was headroom carried
  in.
  - **Assumption:** this section assumes this week's rate continues.
- **Yes, throttle: by about 30%, mostly eternal-machinery on devbox.**
  - Combined demand has to fall from about 7.0 to about 4.8 account-weeks a
    week.
  - eternal-machinery alone uses about **3.3 account-weeks a week**, 65% of
    the pool's capacity.
- **The biggest lever is idle cache rewrites.**
  - On devbox, 78% of prompt-cache write tokens are full-context re-caches
    that happen right after a session sat idle for more than 5 minutes (the
    cache TTL).
  - That is about 45% of devbox's list-price spend, almost all of it EM.
  - Fixing it recovers about 0.9 to 1.1 account-weeks a week, roughly two thirds to
    three quarters of the devbox cut of about 1.4, and only if quota tracks list price (unverified).
  - It is not enough alone. Some real reduction in EM concurrency, or in its
    model mix, is still needed.

## Sources (all read-only)

| Host | What | Where |
|---|---|---|
| devbox | Per-message tokens and stored list-price cost for opencode with providerID `anthropic` (teamclaude, `:3456`) | `~/.local/share/opencode/opencode.db`, read-only; 49,950 assistant messages from 11-14 to 11-22 |
| devbox | Tags | `~/.local/share/oc-tags/tags.db` `session_tag` on the root session, otherwise `auto:<repo>` |
| devbox | Account switches and resets; the quota snapshot | `journalctl --user -t teamclaude`; `~/.config/teamclaude.state.json` |
| cloudbox | Per-request tokens by backend (Vertex or Max), with opencode and goose split by `requestId` | `/var/lib/claude-failover-proxy/events.jsonl` (agrees with the opencode DB to within 0.5%) |
| cloudbox | 7-day % for each account, every 5 min | `/var/lib/teamclaude-pool-canary/quota-samples.jsonl` |

What is and isn't counted:

- **devbox:** the only Max consumer is opencode.
  - goose runs on `openai` (codex-lb), so devbox's goose coordinators cost no
    Max quota.
  - No devbox opencode traffic went to codex-lb this week.
- **cloudbox:**
  - opencode and goose both go through cfp. cfp spends a $100/day Vertex
    budget first, then sends traffic to teamclaude.
  - cloudbox's teamclaude also has a **usage-based Enterprise seat**, with
    `usageSeatFirst` and `maxDailySpend: 100` (see
    `pkgs/teamclaude/default.nix`). It is billed in money and is not part of
    the five-account quota.
  - I assume it absorbed about $100/day of cloudbox's Max-backend traffic,
    which is about 13% of it. That is an estimate. The seat's actual daily
    spend should be read from teamclaude to confirm it.
- **Measured by cloudbox session `ses_dfb8c2cac…`:** the cloudbox figures.
- **Meter:** the bucket that hit 98% on every account is teamclaude's
  `unified7d`, the all-model weekly bucket. The fable-scoped bucket stood at
  5% or less.

## Calibration: tokens to account-weeks

The cloudbox canary records the **account-level** 7-day %. That level counts
both hosts. Summing each account's increases gives:

| Day (ET) | 11-16 | 11-17 | 11-18 | 11-19 | 11-20 | 11-21 | 11-22 (to 18:25, frozen from 17:07Z) |
|---|---|---|---|---|---|---|---|
| Account-weeks used | 0.99 | 1.22 | 1.26 | 1.24 | 0.80 | 0.81 | 0.66 |

That totals about 7.0.

Max quota tokens over the same 7 days:

| Host | cache read | cache write | output | $ at opus-5-5 rates* |
|---|---|---|---|---|
| devbox (UTC days) | 9.28B | 679M | 31M | ~5,880 |
| cloudbox Max backend (ET days) | 7.14B | 671M | 35M | ~5,500 |
| cloudbox, less the usage seat (≈13%) | ~6.2B | ~585M | ~30M | ~4,790 |
| **quota-counted total** | | | | **~10,670** |

\* opencode's stored rates for claude-opus-5-5 are $4 / $0.20 / $5 / $20
per Mtok for input / cache read / cache write / output. These match
`models.json`, and sonnet-5-5 is exactly half of them. I use opus rates for
both hosts so they are comparable. devbox's true list cost was $5,073, because
16% of it went to sonnet.

So **one account-week is about $1,520 at opus-5-5 list price**.

Two observations fit the hosts sharing the accounts, but neither tests it:

- **Single-account stints on devbox.** jonathan.mohrbacher went from 0 to 98%
  over 32 h of devbox use and $1,273 of devbox spend. johnnymo87 took 28 h and
  $815. johnnymo872 took 16 h and $624. All three are below $1,520.
- **After the 22:59Z reset.** johnnymo873 reached 4% in 22 minutes on $40 of
  devbox spend. That is about 11%/h (±25%, because of integer-% samples) while
  the frozen backlog drained.

Neither checks the central **assumption that quota is charged in proportion to
list price**. Anthropic does not publish the weights, and cache reads in
particular may count differently. The direct test is to regress hourly canary
Δ% on the per-class tokens from both hosts. That is the first piece of
proposed automation below.

## Burn rate per host

Sustainable for the pool: 5 account-weeks / 168 h = **2.98% of one account
per hour**.

| | Account-weeks/week | % of one account per hour | List-$ share by class (cache write / cache read / output) |
|---|---|---|---|
| devbox | ~3.9 | ~2.3 | 58% / 32% / 11% |
| cloudbox (quota-counted) | ~3.1 | ~1.9 | 61% / 26% / 13% |
| **both** | **~7.0** | **~4.2** | |
| capacity | 5.0 | 2.98 | |

- Weekdays (11-17 to 11-19) ran at 1.22–1.26 account-weeks a day, about
  5.2%/h.
- Input tokens are negligible.
- The class shares are shares of list price, not of quota.

## By program

Combined account-weeks a week. Each host's share (devbox 55%, cloudbox 45%) is
multiplied by its tag shares.

| Program (host) | Account-weeks/week | %/h |
|---|---|---|
| eternal-machinery (devbox) | **~3.3** | ~1.9 |
| lgtm (cloudbox) | ~0.6 | ~0.35 |
| stall-watcher-runs (cloudbox) | ~0.45 | ~0.26 |
| goose, untagged goose sessions (cloudbox) | ~0.27 | ~0.16 |
| tec-codex (devbox) | ~0.28 | ~0.17 |
| chat-transport (devbox) | ~0.28 | ~0.17 |
| other cloudbox work-program tags, about 8 of them, none over 0.35 | ~1.85 | ~1.1 |
| everything else (devbox) | <0.05 | |

**Stall-watch coordinators:** zero on devbox, which runs goose on codex-lb.
On cloudbox, goose makes up about 30% of Max requests, which falls in
stall-watcher-runs, goose and lgtm.

## Which session shapes drive it (devbox)

- **Big contexts.** Sessions averaging 150–300k context are 59% of devbox
  spend, and those averaging over 300k are 28%. The ten costliest sessions in
  8 days are all EM: $150–390 each, with mean contexts of 210–530k.
- **By agent** (8-day list $): `build` (top-level workers and runners)
  $3,786; `implementer` $883; `adversarial-reviewer-opus` $755; everything
  else under $200.
- **Idle cache rewrites.** I compared each assistant message against the
  previous one in the same session.
  - **Excluded:** the 11-22 freeze onward, any pair spanning an account
    switch, and contexts under 50k.
  - **Full rewrite:** a message whose cache write is at least half its
    context.
  - Probability of a full rewrite, by the gap since the previous message:

    | Gap | P(full rewrite) | Share of all cache-write tokens |
    |---|---|---|
    | <4 min | ≤0.01 | 6% |
    | 4–5 min | 0.01 | 0.4% |
    | 5–6 min | 0.33 | 3.5% |
    | 6–10 min | 0.99 | 16% |
    | 10–30 min | 1.00 | 40% |
    | 30–60 min | 0.99 | 7% |
    | >60 min | 0.99 | 12% |

  - The sharp step at 5 minutes is the 5-minute cache TTL.
  - **78% of cache-write tokens are post-idle re-caches.** EM accounts for
    about 71 of those 78 points.
  - Since cache writes are 58% of devbox list $, that is **about 45% of
    devbox list spend**.
  - The gaps come from sessions that wait: live-window runners, long tool
    runs inside a turn, workers parked on a wake or a peer, and subagents.
    Implementer and reviewer subagents account for about a fifth of the
    re-caches.

## Throttle: how much, where

- **Target: at most about 4.8 account-weeks a week combined.** This is a cut
  of about 2.2 account-weeks, about 30%.
  - **devbox: 2.5 account-weeks a week** (1.5%/h), down from 3.9. That is
    35% less.
  - **cloudbox: 2.3 account-weeks a week** (1.4%/h) on the quota accounts,
    down from 3.1. That is 27% less.
- **eternal-machinery: from 3.3 down to about 2.0.** Options, cheapest first:
  1. **Stop idle re-caches.** Two mechanisms:
     - **1-hour cache TTL.** Writes are billed at 2× input instead of 1.25×,
       and this applies to *all* writes. The 6–60 minute bins (about 63% of
       write tokens) become reads. Net write spend falls by about 43%, or
       about 25% of devbox spend, which is **about 0.9 account-weeks a
       week**.
     - **Keepalive.** A cache read sent every 4.5 minutes to a waiting
       large-context session costs about 4% of a rewrite per ping, with no
       premium on any other write. It saves a little more, about 1.0–1.1,
       but sends more requests.
     - Both require the next request to land on the **same account**, since
       the prompt cache is per account, so a teamclaude rotation defeats
       them.
     - The 1-hour TTL also requires the Max OAuth path to honour
       `ttl: 1h`.
     - Both assume quota tracks list price.
     - **Measure on one EM runner before relying on either.**
  2. **Model mix.** implementer and reviewer subagents cost $1,638 of devbox
     spend in 8 days. If Max weights sonnet below opus in `unified7d`,
     moving them to sonnet is a large lever. The weighting is unknown.
  3. **Concurrency.** Cap concurrent EM workers and live-window runners.
     Each continuously busy large-context EM session runs roughly 0.3–0.5
     account-weeks a week.
- **cloudbox:**
  - The candidates are lgtm and stall-watcher-runs (about 1.0 account-weeks
    between them), plus the larger work-program sessions.
  - Money levers exist, and they are capacity, which was ruled out:
    - Raise cfp's Vertex budget. One account-week is about $1,520 at Vertex
      list, so moving 1 account-week a week costs about $220/day.
    - Raise the usage seat's `maxDailySpend`.
- **Don't throttle what is nearly free.** devbox goose coordinators,
  tec-codex and chat-transport are about 0.55 account-weeks combined.

## Proposed automation (not built: Jonathan decides)

1. **Pool exhaustion forecast** (cloudbox, from the existing canary).
   - **Inputs:**
     - remaining headroom, Σ(1 − uᵢ) across the five accounts;
     - refills from resets due before time T;
     - the trailing 12–24 h burn rate.
   - **Primary signal:** alert, through pigeon or ntfy to the
     eternal-machinery channel, when projected exhaustion falls before the
     next reset that would cover it.
   - **Why not a fixed daily threshold:** this week's normal days ran 0.8–1.26
     account-weeks a day against 0.71 a day sustainable. A fixed threshold
     would have alarmed every day.
   - **Calibration:** each week, regress hourly Δ% on per-class tokens from
     both hosts. That keeps the token-to-quota factor honest, and it tests
     the list-price assumption.
2. **Per-host and per-program attribution.**
   - **Inputs:** devbox opencode rows with provider `anthropic`; cloudbox cfp
     rows with `backend=max`, less the usage seat's spend.
   - Convert both with the factor from (1).
   - **Concrete shape:** add `--provider`/`--backend` and an account-weeks
     column to `session-tags report`. Today it mixes Vertex, codex-lb and Max.
3. **Budgets with warnings, not hard stops.**
   - devbox at 2.5 account-weeks a week, cloudbox at 2.3, eternal-machinery
     at 2.0.
   - Warn at 80% of the pro-rated budget, aimed at humans and coordinators.
4. **Later, optional enforcement.**
   - **cloudbox:** cfp already routes by budget. It could shed low-priority
     automation, or overflow to Vertex, when (1) forecasts exhaustion.
   - **devbox:** the cfp-shaper already in front of teamclaude could cap
     concurrency for a program that is over budget.
5. **Cache experiment.** Try the 1-hour TTL, or a keepalive, for sessions
   over 150k context. A/B it on one EM runner and read the effect through (1).

## Caveats

- **Day boundaries:** devbox is bucketed by UTC day and cloudbox by ET day.
- **The 7.0 figure:** it is a floor, because the freeze suppressed demand.
  jonathan.mohrbacher reported no usage data on cloudbox on 11-22, so the
  canary may undercount it.
- **The usage seat:** its share (13%) is an assumption. Read it from
  teamclaude's spend probe.
- **Combined program shares:** each is host share × tag share. They are not a
  direct join across hosts.
- **The list-price-to-quota mapping:** it holds in aggregate for this week's
  mix only.
