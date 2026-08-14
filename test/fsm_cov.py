# ZIRH - FSM transition coverage collector (H42)
#
# Suites start watch() on their FSM state signals; at test end the
# observed (from, to) pairs land in test/cov/<tag>.json and
# scripts/coverage_report.py gates them against the expected sets.
import json
import os

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge


def watch(dut, sig, tag):
    seen = set()

    async def mon():
        prev = None
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            v = sig.value
            cur = int(v) if v.is_resolvable else None
            if prev is not None and cur is not None and cur != prev:
                seen.add((prev, cur))
            prev = cur
    cocotb.start_soon(mon())
    return seen


def dump(tag, seen):
    os.makedirs("cov", exist_ok=True)
    with open(f"cov/{tag}.json", "w") as f:
        json.dump(sorted([list(t) for t in seen]), f)
