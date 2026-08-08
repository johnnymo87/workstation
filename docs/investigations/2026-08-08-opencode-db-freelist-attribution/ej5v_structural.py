#!/usr/bin/env python3
"""workstation-ej5v: close review holes H1 (overflow by arithmetic, not
elimination) and H2 (structural attribution, not substring precedence).

H2: decode each freed leaf_table page's cells properly -- cell pointer array,
varint payload size, varint rowid, then the record header's serial types -- and
read the ACTUAL first column (the text PK). A part page whose payload merely
mentions 'evt_' can no longer masquerade as an event page, because we read the
PK, not the page's bytes at large.

H1: from the same decoded cells, compute each row's spill using SQLite's real
maxLocal/minLocal formulas and sum the overflow pages the event rows must have
owned. If that predicts the observed 79.1% overflow share, overflow mass is
measured rather than attributed by elimination.

Read-only.
"""
import struct
import random
import sys
import re
from array import array
from collections import Counter

PATH = sys.argv[1]
NSAMP = int(sys.argv[2]) if len(sys.argv) > 2 else 30000
PS = 4096

f = open(PATH, "rb")
h = f.read(100)
RESERVED = h[20]
USABLE = PS - RESERVED
NPAGES = struct.unpack(">I", h[28:32])[0]
TRUNK = struct.unpack(">I", h[32:36])[0]
NFREE = struct.unpack(">I", h[36:40])[0]
print(f"page_size={PS} reserved={RESERVED} usable={USABLE} pages={NPAGES:,} freelist={NFREE:,}")

# max/min local for a table b-tree leaf
MAXLOCAL = USABLE - 35
MINLOCAL = ((USABLE - 12) * 32 // 255) - 23
print(f"maxLocal={MAXLOCAL} minLocal={MINLOCAL}")


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


def spill_pages(P):
    """overflow pages owned by a table-leaf cell of total payload P"""
    if P <= MAXLOCAL:
        return 0, P
    K = MINLOCAL + ((P - MINLOCAL) % (USABLE - 4))
    local = K if K <= MAXLOCAL else MINLOCAL
    rest = P - local
    return -(-rest // (USABLE - 4)), local


# ---- walk freelist --------------------------------------------------------
leaves = array("I")
trunks = array("I")
t, seen = TRUNK, set()
while t and t not in seen:
    seen.add(t)
    b = rd(t)
    trunks.append(t)
    nxt = struct.unpack(">I", b[0:4])[0]
    L = struct.unpack(">I", b[4:8])[0]
    for i in range(L):
        leaves.append(struct.unpack(">I", b[8 + 4 * i:12 + 4 * i])[0])
    t = nxt

# pending-byte page can never be allocated; assert it is absent (reviewer check)
PENDING = (2 ** 30 // PS) + 1
allfree = set(leaves) | set(trunks)
print(f"pending-byte page {PENDING:,} in freelist? {PENDING in allfree}  (must be False)")
print(f"page 1 in freelist? {1 in allfree}  (must be False)")

random.seed(20260808)
samp = random.sample(list(leaves), min(NSAMP, len(leaves)))

kinds = Counter()
pk = Counter()
shape = Counter()
ncells_tot = 0
spill_tot = 0
payload_tot = 0
big = 0
bad = 0
ID_RE = re.compile(rb"^[a-z]{3}_[0-9a-zA-Z]+$")

for p in samp:
    b = rd(p)
    c = b[0]
    if c == 0x0D:
        kinds["leaf_table"] += 1
    elif c == 0x0A:
        kinds["leaf_index"] += 1
        continue
    elif c == 0x00:
        kinds["overflow"] += 1
        continue
    elif c in (0x02, 0x05):
        kinds["interior"] += 1
        continue
    else:
        kinds[f"other_0x{c:02x}"] += 1
        continue

    ncell = struct.unpack(">H", b[3:5])[0]
    if ncell == 0 or 8 + 2 * ncell > PS:
        bad += 1
        continue
    for ci in range(ncell):
        off = struct.unpack(">H", b[8 + 2 * ci:10 + 2 * ci])[0]
        if off < 8 or off >= PS:
            bad += 1
            continue
        try:
            P, i = varint(b, off)          # total payload bytes
            rowid, i = varint(b, i)        # rowid
            hlen, j = varint(b, i)         # record header length
            if not (1 <= hlen <= 200) or P <= 0 or P > 2 ** 31:
                bad += 1
                continue
            # serial types
            stypes = []
            k = j
            while k < i + hlen and len(stypes) < 40:
                s, k = varint(b, k)
                stypes.append(s)
            if not stypes:
                bad += 1
                continue
            s0 = stypes[0]
            if s0 < 13 or s0 % 2 == 0:
                shape[f"col0_not_text(serial={s0})"] += 1
                continue
            ln = (s0 - 13) // 2
            val = b[i + hlen:i + hlen + ln]
            if len(val) != ln:
                bad += 1
                continue
            ncells_tot += 1
            payload_tot += P
            sp, _loc = spill_pages(P)
            spill_tot += sp
            if sp:
                big += 1
            shape[f"ncols={len(stypes)}"] += 1
            m = ID_RE.match(val)
            pk[val[:4].decode("latin1") if m else f"NONID({val[:12]!r})"] += 1
        except (IndexError, struct.error):
            bad += 1

print(f"\nsampled {len(samp):,} freed pages; kinds: {dict(kinds)}")
print(f"cells structurally decoded: {ncells_tot:,}  (undecodable cells: {bad:,})")
print("\nH2 -- ACTUAL first-column primary key prefix (structural, not substring):")
for k, v in pk.most_common(12):
    print(f"    {k:>28}: {v:>8,} ({100*v/max(1,ncells_tot):6.2f}%)")
print("\n  record shape (column count) of decoded cells:")
for k, v in shape.most_common(8):
    print(f"    {k:>28}: {v:>8,}")

lt = kinds["leaf_table"]
if lt:
    cells_per_leaf = ncells_tot / lt
    spill_per_leaf = spill_tot / lt
    est_leaves = NFREE * lt / len(samp)
    print(f"\nH1 -- overflow accounted by arithmetic:")
    print(f"    mean payload P = {payload_tot/max(1,ncells_tot):,.0f} bytes/row")
    print(f"    cells/leaf = {cells_per_leaf:.2f}; rows that spill = {100*big/max(1,ncells_tot):.1f}%")
    print(f"    overflow pages owed per freed leaf = {spill_per_leaf:.2f}")
    print(f"    freed leaf_table pages in freelist ~ {est_leaves:,.0f}")
    print(f"    => predicted overflow pages = {est_leaves*spill_per_leaf:,.0f}")
    obs_ov = NFREE * kinds["overflow"] / len(samp)
    print(f"    => observed  overflow pages = {obs_ov:,.0f}")
    if obs_ov:
        print(f"    predicted/observed = {est_leaves*spill_per_leaf/obs_ov:.2f}")
f.close()
