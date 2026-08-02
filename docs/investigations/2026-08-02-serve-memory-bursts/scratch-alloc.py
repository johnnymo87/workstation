#!/usr/bin/env python3
"""Slow-growing, COMPRESSIBLE anonymous allocator for the step-2 scratch test.

Deliberately compressible (a repeated byte pattern) and deliberately slow: a
fast allocator writing incompressible pages outruns zram and gets OOM-killed
for capacity reasons, which would make the whole experiment pass vacuously.

argv: <rate_mb_per_s> <cap_mb|0 for unbounded>
Holds every chunk in a list so nothing is ever freed.
"""
import sys, time

rate = int(sys.argv[1])
cap = int(sys.argv[2])
CHUNK = 16 * 1024 * 1024
_page = (b"COMPRESSIBLE" * 342)[:4096]
assert len(_page) == 4096, len(_page)
pattern = _page * (CHUNK // 4096)
assert len(pattern) == CHUNK, len(pattern)

held = []
t0 = time.time()
while True:
    held.append(bytearray(pattern))  # bytearray forces a real private copy
    # Count ACTUAL retained bytes. An earlier version incremented an assumed
    # per-chunk constant and silently over-reported by 5.3x, which would have
    # produced a vacuous "no OOM" pass.
    mb = sum(len(x) for x in held) // (1024 * 1024)
    if cap and mb >= cap:
        break
    print(f"allocated {mb}MB t={time.time()-t0:.0f}s", flush=True)
    time.sleep(CHUNK / (1024 * 1024) / rate)

print(f"HOLDING at {mb}MB — allocation complete, not exiting", flush=True)
while True:
    time.sleep(5)
