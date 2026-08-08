# What created the 5.59 GiB freelist in opencode.db?

**Date:** 2026-08-08 · **Bead:** `workstation-ej5v` (closed) · **Follow-up:** `workstation-vaeg`

## Answer

A **one-time opencode schema migration**, not ongoing churn.

`20260622170816_reset_v2_session_state`, applied **2026-07-06 18:59:44 UTC**:

```sql
DELETE FROM `session_context_epoch`;
DELETE FROM `session_input`;
DELETE FROM `session_message`;
DELETE FROM `event`;
DELETE FROM `event_sequence`;
UPDATE  `session` SET `workspace_id` = NULL WHERE `workspace_id` IS NOT NULL;
DELETE FROM `workspace`;
```

`20260622202450_simplify_session_input` has a **byte-identical** body and ran 10 s
later, so the block executed twice. The mass is the `event` table.

## Why the previous two attributions were wrong

| Attribution | Why it failed |
|---|---|
| opencode's `cleanup prune=7.days` (believed until 2026-08-08) | That log line follows `git gc --prune=7.days` on the Snapshot gitdir. Filesystem git objects cannot free a SQLite page. Disproven in `workstation-nx9n`. |
| "hypothesis only, no evidence it ran" (`workstation-ej5v` as opened) | The execution record exists — in a table called **`migration`** (38 rows). The prior investigation checked `data_migration` (2 rows) and `__drizzle_migrations` (newest 2026-06-07), which are *different ledgers*. |

**If you take one thing from this doc:** opencode has three migration ledgers.
Query `migration` — not just `data_migration` and `__drizzle_migrations`.

## Evidence chain

1. **Complete freelist walk** (not sampled): 1,442 trunk + 1,464,835 leaf =
   **1,466,277**, exactly the header's `freelist_count`. Guards passed —
   pending-byte page 262,145 absent, page 1 absent, reserved bytes 0.
2. **Structural attribution**: decoded freed leaf pages properly (cell pointer
   array → varint payload size → varint rowid → record header serial types) and
   read the *actual* first column. **17,459 / 17,459 cells have an `evt_` PK and
   exactly 5 columns**, matching `event(id, aggregate_id, seq, type, data)`.
   Zero `part`, zero `message`.
3. **Falsification test (passed)**: `event` is never repopulated (0 rows in both
   the pre-VACUUM backup and live), so no freed page may reference a session
   created after the migration. Of 4,091 recovered `ses_` ids, 1,178 resolve;
   all span 2026-05-12 .. 2026-06-29. **Zero after 2026-07-06.**
4. **Single-sweep signature**: the `evt_` id field is monotone across all ~1.4M
   freelist positions. A bulk `DELETE` frees pages in btree scan order onto a
   LIFO freelist; interleaved churn would scramble that.
5. **Churn excluded by construction**: in non-autovacuum SQLite every page is the
   same size and the allocator drains the freelist before extending the file, so
   churn frees and immediately *reuses*. It cannot **accumulate** a freelist —
   accumulation is itself proof of a net deletion.

## Numbers (corrected)

| | |
|---|---|
| Freelist | **1,466,277 pages / 5.59 GiB** (the inherited "~1.6M pages" was wrong) |
| Backup | 13,042,720,768 B; page_count 3,184,258; in_use 1,717,981 |
| Live post-VACUUM | page_count 1,686,836; freelist 0 |
| Original deletion | ≥1.47M pages, est. <1.50M (1.47M is what *survived* 33 days of reuse) |
| Live net allocation | ~685 pages/day |

## Scripts

All read-only. They parse the file directly rather than going through `sqlite3`,
so they cannot write, cannot VACUUM, and never touch the live DB.

| Script | Purpose |
|---|---|
| `ej5v_freewalk.py` | Walk the freelist; run-length + file-decile profile |
| `ej5v_classify.py` | First-pass page classification (**superseded — see caveat**) |
| `ej5v_structural.py` | Structural cell decode + overflow spill arithmetic |
| `ej5v_tail.py` | Payload tail statistics + single-sweep time gradient |

```bash
python3 ej5v_structural.py /path/to/opencode.db.backup 30000
```

### Caveat on `ej5v_classify.py`

It attributes pages by **substring** with `evt_ > prt_ > msg_` precedence. That
rule can *fabricate* a "zero part/message" result, because `part.data` on this
box routinely quotes `evt_` ids in tool output. Adversarial review caught it;
`ej5v_structural.py` was written to replace it and reads the real PK. The
original is kept only to show what the weaker instrument claimed.

## Traps worth remembering

- **`bin/opencode` is a wrapper.** The 168 MB bundle is `bin/.opencode-wrapped`.
  Grepping the wrapper returns 0 for everything and looks like real absence.
- **The migration SQL uses backticks.** `grep 'DELETE FROM event'` returns 0;
  `DELETE FROM \`event\`` is the string.
- **Overflow pages have no type byte.** First byte 0x00 identifies them here only
  because every page number is < 2²⁴, so the next-pointer's high byte is zero.
- **`event.data` is violently heavy-tailed.** Top 1 % of rows own 74 % of all
  spill; one row owns 2,602 overflow pages (10.6 MB). Any per-row estimator is
  tail-dominated — enlarging the sample 17k → 71k cells moved overflow
  accounting 0.74 → 0.85. Budget for that variance instead of chasing a
  "missing" page population.
- **Session ids decode, event ids do not (with the same transform).**
  `time_ms = 1786706395135 - (id_hex >> 12)` fits `ses_` exactly and returns
  nonsense 2024 dates for `evt_`. Don't reuse it across id prefixes.

## Forward prediction

Recorded in `workstation-vaeg` **before** the 2026-09-07 check, so it cannot be
graded post-hoc:

- **Confirms** — `freelist_count` small and *plateauing* (1e3–1e5), `page_count`
  growing ~685/day.
- **Falsifies** — `freelist_count` growing monotonically toward 1e6. Then a
  recurring net-deletion source exists that this investigation missed: **stop and
  re-measure before any VACUUM**, since a periodic VACUUM would paper over it.

"Freelist stays exactly 0" is the **wrong** success criterion — ordinary session
deletion keeps a small nonzero plateau, and grading against 0 false-alarms on the
first reset cycle.
