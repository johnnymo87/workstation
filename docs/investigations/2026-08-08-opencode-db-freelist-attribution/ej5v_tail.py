#!/usr/bin/env python3
"""workstation-ej5v / review hole H1: the overflow-accounting shortfall.

The spill estimator sums overflow pages owed by decoded event rows. event.data
payloads are heavy-tailed (a giant tool output is one row), so the estimator's
variance is dominated by rare huge rows. This run enlarges the leaf sample and
reports the payload tail, so we can say whether a 26% shortfall is estimator
variance or an unexplained population of overflow pages.

Also does H6: the time gradient across the freelist, which distinguishes ONE
bulk deletion from interleaved churn.

Read-only.
"""
import struct
import random
import sys
from array import array
from collections import Counter

PATH = sys.argv[1]
NREAD = int(sys.argv[2]) if len(sys.argv) > 2 else 120000
PS = 4096
USABLE = 4096
MAXLOCAL = USABLE - 35
MINLOCAL = ((USABLE - 12) * 32 // 255) - 23

f = open(PATH, "rb")
h = f.read(100)
NFREE = struct.unpack(">I", h[36:40])[0]
TRUNK = struct.unpack(">I", h[32:36])[0]


def rd(n):
    f.seek((n - 1) * PS)
    return f.read(PS)


def varint(b, i):
    v = 0
    for k in range(9):
        c = b[i + k]
        if k == 8:
            return (v << 8) | c, i + 9
        v = (v << 7) | (c & 0x7F)
        if not (c & 0x80):
            return v, i + k + 1
    return v, i + 9


def spill(P):
    if P <= MAXLOCAL:
        return 0
    K = MINLOCAL + ((P - MINLOCAL) % (USABLE - 4))
    local = K if K <= MAXLOCAL else MINLOCAL
    return -(-(P - local) // (USABLE - 4))


leaves = array("I")
t, seen = TRUNK, set()
order = {}
pos = 0
while t and t not in seen:
    seen.add(t)
    b = rd(t)
    nxt = struct.unpack(">I", b[0:4])[0]
    L = struct.unpack(">I", b[4:8])[0]
    for i in range(L):
        pg = struct.unpack(">I", b[8 + 4 * i:12 + 4 * i])[0]
        leaves.append(pg)
        order[pg] = pos
        pos += 1
    t = nxt

random.seed(4242)
samp = random.sample(list(leaves), min(NREAD, len(leaves)))
nleaf = nov = 0
spills = []
ids = []
for p in samp:
    b = rd(p)
    if b[0] == 0x00:
        nov += 1
        continue
    if b[0] != 0x0D:
        continue
    nleaf += 1
    ncell = struct.unpack(">H", b[3:5])[0]
    for ci in range(ncell):
        try:
            off = struct.unpack(">H", b[8 + 2 * ci:10 + 2 * ci])[0]
            if off < 8 or off >= PS:
                continue
            P, i = varint(b, off)
            _rowid, i = varint(b, i)
            hlen, j = varint(b, i)
            s0, _ = varint(b, j)
            if s0 < 13 or s0 % 2 == 0 or P <= 0 or P > 2 ** 31:
                continue
            ln = (s0 - 13) // 2
            val = b[i + hlen:i + hlen + ln]
            if len(val) != ln or not val.startswith(b"evt_"):
                continue
            spills.append(spill(P))
            ids.append((order[p], val[4:16].decode("latin1")))
        except (IndexError, struct.error):
            continue

spills.sort()
n = len(spills)
tot = sum(spills)
print(f"read {len(samp):,} freed pages -> leaf_table={nleaf:,} overflow={nov:,}")
print(f"event cells decoded: {n:,}; total spill pages owed = {tot:,}")
print(f"\npayload tail (overflow pages per row):")
for q in (50, 75, 90, 95, 99, 99.9):
    print(f"    p{q:<5}: {spills[min(n-1,int(n*q/100))]:>8,}")
print(f"    max  : {spills[-1]:,}")
top1 = sum(spills[int(n * 0.99):])
top01 = sum(spills[int(n * 0.999):])
print(f"  share of ALL spill owed by top 1% of rows : {100*top1/tot:5.1f}%")
print(f"  share of ALL spill owed by top 0.1% of rows: {100*top01/tot:5.1f}%")
print("  -> if a few % of rows own most spill, the estimator is tail-dominated")
print("     and a 25% shortfall is variance, not a missing page population.")

est_leaves = NFREE * nleaf / len(samp)
pred = est_leaves * (tot / nleaf)
obs = NFREE * nov / len(samp)
print(f"\nH1 rerun (larger sample, seed 4242):")
print(f"    predicted overflow pages = {pred:,.0f}")
print(f"    observed  overflow pages = {obs:,.0f}")
print(f"    predicted/observed = {pred/obs:.2f}")

# H6: time gradient across freelist order
print("\nH6 -- time gradient across freelist position:")
ids.sort()
step = max(1, len(ids) // 10)
for k in range(0, len(ids) - step, step):
    chunk = ids[k:k + step]
    hexes = sorted(x[1] for x in chunk)
    print(f"    freelist pos ~{chunk[0][0]:>9,}: id-time median {hexes[len(hexes)//2]}")
f.close()
