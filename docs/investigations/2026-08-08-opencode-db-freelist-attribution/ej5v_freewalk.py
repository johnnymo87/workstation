#!/usr/bin/env python3
"""workstation-ej5v: read-only forensics on the pre-W3 opencode.db backup.

Walks the SQLite freelist WITHOUT sqlite3, purely by parsing the file, so it
cannot write, cannot VACUUM, and cannot touch the live DB. Emits:
  1. the trunk/leaf structure of the freelist
  2. the contiguity (run-length) profile of freed pages
  3. a content classification of a random sample of freed leaf pages

Free pages are not zeroed by SQLite unless secure_delete is on, so a freed leaf
page still holds the stale bytes of whatever it used to be. That is the actual
evidence for WHICH table was churning; dbstat cannot answer it (dbstat reports
only in-use pages).
"""
import os
import struct
import sys
import random
from array import array
from collections import Counter

PATH = sys.argv[1]
SAMPLE = int(sys.argv[2]) if len(sys.argv) > 2 else 500
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 20260808

f = open(PATH, "rb")
hdr = f.read(100)
assert hdr[:16] == b"SQLite format 3\x00", "not a sqlite db"
PS = struct.unpack(">H", hdr[16:18])[0]
PS = 65536 if PS == 1 else PS
NPAGES = struct.unpack(">I", hdr[28:32])[0]
TRUNK = struct.unpack(">I", hdr[32:36])[0]
NFREE = struct.unpack(">I", hdr[36:40])[0]


def page(n):
    """1-indexed page read."""
    f.seek((n - 1) * PS)
    return f.read(PS)


print(f"page_size={PS} page_count={NPAGES:,} freelist_count={NFREE:,} first_trunk={TRUNK}")

# ---- 1. walk the freelist -------------------------------------------------
leaves = array("I")
trunks = array("I")
seen = set()
t = TRUNK
while t:
    if t in seen:
        print(f"!! trunk cycle at {t}")
        break
    seen.add(t)
    trunks.append(t)
    b = page(t)
    nxt = struct.unpack(">I", b[0:4])[0]
    L = struct.unpack(">I", b[4:8])[0]
    if L > (PS // 4) - 2:
        print(f"!! implausible leaf count {L} on trunk {t}; stopping")
        break
    for i in range(L):
        leaves.append(struct.unpack(">I", b[8 + 4 * i:12 + 4 * i])[0])
    t = nxt

total = len(trunks) + len(leaves)
print(f"trunks={len(trunks):,} leaves={len(leaves):,} total={total:,} "
      f"header_says={NFREE:,} match={total == NFREE}")

# ---- 2. contiguity profile ------------------------------------------------
# Bulk deletion of a big table frees long contiguous runs of pages.
# Incremental churn frees pages scattered across the file.
allfree = sorted(set(list(trunks) + list(leaves)))
runs = []
start = prev = allfree[0]
for p in allfree[1:]:
    if p == prev + 1:
        prev = p
        continue
    runs.append((start, prev - start + 1))
    start = prev = p
runs.append((start, prev - start + 1))
rl = [r[1] for r in runs]
rl_sorted = sorted(rl, reverse=True)
print(f"\nfree pages span {allfree[0]:,}..{allfree[-1]:,}  runs={len(runs):,}")
print(f"  mean_run={sum(rl)/len(rl):.1f} median_run={sorted(rl)[len(rl)//2]} "
      f"max_run={rl_sorted[0]:,}")
buckets = Counter()
for n in rl:
    if n == 1:
        buckets["1"] += n
    elif n < 8:
        buckets["2-7"] += n
    elif n < 64:
        buckets["8-63"] += n
    elif n < 1024:
        buckets["64-1023"] += n
    else:
        buckets[">=1024"] += n
print("  pages by run length:")
for k in ["1", "2-7", "8-63", "64-1023", ">=1024"]:
    print(f"    {k:>8}: {buckets[k]:>10,} ({100*buckets[k]/total:5.1f}%)")
print(f"  top runs: {rl_sorted[:10]}")

# where in the file do free pages sit? (deciles)
dec = Counter()
for p in allfree:
    dec[min(9, (p - 1) * 10 // NPAGES)] += 1
print("  free pages by file decile (0=start .. 9=end):")
print("   ", " ".join(f"{dec[i]*100//total:>3}%" for i in range(10)))

# ---- 3. content classification of freed leaf pages ------------------------
random.seed(SEED)
samp = random.sample(list(leaves), min(SAMPLE, len(leaves)))
PTYPE = {0x02: "interior_index", 0x05: "interior_table",
         0x0A: "leaf_index", 0x0D: "leaf_table", 0x00: "zeroed"}
ptypes = Counter()
marks = Counter()
zero_pages = 0
# distinctive byte markers; tuned after seeing the schema
MARKERS = [
    (b"tool", "tool"), (b"text", "text"), (b"reasoning", "reasoning"),
    (b"step-start", "step-start"), (b"step-finish", "step-finish"),
    (b"msg_", "msg_id"), (b"prt_", "prt_id"), (b"ses_", "ses_id"),
    (b"snapshot", "snapshot"), (b"patch", "patch"),
    (b"assistant", "assistant"), (b"user", "user"),
    (b"event", "event"), (b"session_context_epoch", "sce"),
    (b"http", "http"), (b"file://", "file://"),
]
for p in samp:
    b = page(p)
    ptypes[PTYPE.get(b[0], f"other_0x{b[0]:02x}")] += 1
    if not any(b):
        zero_pages += 1
    for pat, name in MARKERS:
        if pat in b:
            marks[name] += 1
print(f"\nsampled {len(samp)} freed leaf pages (seed={SEED})")
print(f"  all-zero pages: {zero_pages} ({100*zero_pages/len(samp):.1f}%)  "
      f"-> if high, secure_delete/zeroing hid the evidence")
print("  stale page-type byte:", dict(ptypes))
print("  marker hit counts:")
for k, v in marks.most_common():
    print(f"    {k:>14}: {v:>4} ({100*v/len(samp):5.1f}%)")
f.close()
