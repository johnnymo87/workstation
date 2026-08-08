#!/usr/bin/env python3
"""workstation-ej5v: attribute freed pages in the pre-W3 backup to a table.

Read-only. Classifies a large random sample of freelist leaf pages.

Rule for btree leaf pages: opencode row ids are prefixed (evt_/prt_/msg_/ses_).
`event` rows are (id evt_, aggregate_id ses_, seq, type, data), and event.data
embeds a whole part JSON -- so an event page also contains prt_/msg_/ses_.
Precedence is therefore evt_ > prt_ > msg_ > ses_, and the competing hypothesis
(ordinary part/message churn) would show up as pages carrying prt_/msg_ WITHOUT
evt_. That asymmetry is what makes the count decisive rather than suggestive.
"""
import struct
import random
import sys
from array import array
from collections import Counter

PATH = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
PS = 4096
f = open(PATH, "rb")
h = f.read(100)
TRUNK = struct.unpack(">I", h[32:36])[0]

leaves = array("I")
t, seen = TRUNK, set()
while t and t not in seen:
    seen.add(t)
    f.seek((t - 1) * PS)
    b = f.read(PS)
    nxt = struct.unpack(">I", b[0:4])[0]
    L = struct.unpack(">I", b[4:8])[0]
    for i in range(L):
        leaves.append(struct.unpack(">I", b[8 + 4 * i:12 + 4 * i])[0])
    t = nxt

random.seed(20260808)
samp = random.sample(list(leaves), min(N, len(leaves)))
kind = Counter()
tbl = Counter()
ovmark = Counter()
for p in samp:
    f.seek((p - 1) * PS)
    b = f.read(PS)
    c = b[0]
    if c == 0x0D:
        k = "leaf_table"
    elif c == 0x0A:
        k = "leaf_index"
    elif c == 0x05:
        k = "interior_table"
    elif c == 0x02:
        k = "interior_index"
    elif c == 0x00:
        k = "overflow"
    else:
        k = f"other_0x{c:02x}"
    kind[k] += 1
    if k in ("leaf_table", "leaf_index", "interior_table", "interior_index"):
        if b"evt_" in b:
            tbl[k + "/event"] += 1
        elif b"prt_" in b:
            tbl[k + "/part"] += 1
        elif b"msg_" in b:
            tbl[k + "/message"] += 1
        elif b"ses_" in b:
            tbl[k + "/session-ish"] += 1
        else:
            tbl[k + "/unidentified"] += 1
    elif k == "overflow":
        # event.data wraps the part in {"part":{...}} and carries the event
        # envelope keys; part.data does not.
        hit = False
        for pat, name in ((b'"part":{', "event-envelope"),
                          (b"message.part.updated", "event-type"),
                          (b"session.updated", "event-type"),
                          (b'"sessionID":', "sessionID-key")):
            if pat in b:
                ovmark[name] += 1
                hit = True
        if not hit:
            ovmark["no-marker(mid-payload)"] += 1

tot = len(samp)
print(f"sampled {tot:,} of {len(leaves):,} freelist leaf pages (seed 20260808)")
print("\npage kind:")
for k, v in kind.most_common():
    print(f"  {k:>16}: {v:>7,} ({100*v/tot:5.1f}%)")
print("\nbtree pages attributed by id-prefix precedence (evt_ > prt_ > msg_ > ses_):")
btot = sum(v for k, v in tbl.items())
for k, v in tbl.most_common():
    print(f"  {k:>32}: {v:>7,} ({100*v/btot:5.1f}% of btree, {100*v/tot:4.1f}% of all)")
print("\noverflow page markers (non-exclusive):")
for k, v in ovmark.most_common():
    print(f"  {k:>24}: {v:>7,}")
f.close()
