# =============================================================================
# ZIRH-3 - top-level traffic storm (Cycle 26)
#
# The SV storm abuses the loader at its own boundary; this one abuses
# the WHOLE die at the pins, with the CPU running and telemetry
# flowing. Its first draft assumed the loader keeps listening - and
# the storm immediately proved it does not. The contract, read back
# from the FSM and now LOCKED by these oracles:
#
#   - the loader rules ONCE per reset: after commit (S_RUN) or reject
#     (S_GOLDEN) it goes deaf; a second image is silence, not an event
#   - line garbage while the loader is ARMED poisons the frame: at 12
#     bytes it draws a bad-magic reject, under 12 it eats the next
#     image's bytes - either way the arm is spent
#   - re-arming is a RESET, exactly as flight operations would do it
#
# The storm runs in blocks: each block re-arms with a POR, spends the
# arm on a rotating first move (good / corrupt / garbage), then pokes
# the now-deaf loader with closed-state traffic that must change
# NOTHING - a committed program must keep flooding through rejected
# images and garbage alike. Coverage bins are guaranteed by rotation;
# a hole fails the storm.
#
# GL_FUZZ_SEED picks the storm; the schedule is deterministic per seed.
# =============================================================================

import os
import random

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from test_top_isp import (DIV, PROGRAM, image, start, uart_send)

# three back-to-back 'Z' frames on the wire, LSB first with framing:
# start(0) 01011010 stop(1) - the flood's bit-level signature
Z_TRIPLE = "0010110101" * 3


async def z_signature(dut, tries=3, window_bits=600):
    """hunt_z_flood aligns from silence; a storm that checks the flood
    WHILE it streams has no silence to align from - a mid-frame lock
    reads the same wrong byte forever (the bench's own hunt_echo
    docstring called this trap years before it bit). So: sample the
    pin at the bit period and search the flood's bit pattern at ANY
    offset - alignment-free by construction."""
    for _ in range(tries):
        bits = []
        for _ in range(window_bits):
            await ClockCycles(dut.clk, DIV)
            bits.append(str(int(dut.uart_tx_o.value)))
        if Z_TRIPLE in "".join(bits):
            return True
    return False


async def repor(dut):
    # reset choreography of start(), without spawning a second clock
    dut.rst_n_pad.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst_n_pad.value = 1
    await ClockCycles(dut.clk, 60)


@cocotb.test()
async def test_die_shrugs_off_the_traffic_storm(dut):
    seed = int(os.environ.get("GL_FUZZ_SEED", "1"))
    rng = random.Random(seed)

    rejects = [0]

    async def count_rejects():
        prev = 0
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            cur = int(dut.evt_boot_reject_o.value)
            if cur and not prev:
                rejects[0] += 1
            prev = cur

    cocotb.start_soon(count_rejects())
    await start(dut, strap=1)

    bins = {"armed_good": 0, "armed_corrupt": 0, "armed_garbage": 0,
            "closed_good": 0, "closed_corrupt": 0, "closed_garbage": 0,
            "idle": 0}

    async def send_good():
        for b in image(PROGRAM):
            await uart_send(dut, b)
        await ClockCycles(dut.clk, 500)

    async def send_corrupt():
        for b in image(PROGRAM, crc=0xDEADBEEF):
            await uart_send(dut, b)
        await ClockCycles(dut.clk, 500)

    async def send_garbage():
        for _ in range(rng.randrange(4, 40)):
            await uart_send(dut, rng.randrange(256))
        await ClockCycles(dut.clk, 500)

    N_BLOCKS = 9
    for blk in range(N_BLOCKS):
        await repor(dut)
        booted = False

        # spend the arm: the rotation guarantees every armed bin thrice
        first = ("good", "corrupt", "garbage")[blk % 3]
        if first == "good":
            bins["armed_good"] += 1
            await send_good()
            assert int(dut.boot_sel_o.value) == 1, \
                f"block {blk}: armed good image must commit (seed {seed})"
            assert await z_signature(dut), \
                f"block {blk}: committed program never flooded (seed {seed})"
            booted = True
        elif first == "corrupt":
            bins["armed_corrupt"] += 1
            before = rejects[0]
            await send_corrupt()
            assert rejects[0] > before, \
                f"block {blk}: armed corrupt image must draw a reject (seed {seed})"
            assert int(dut.boot_sel_o.value) == 0
        else:
            bins["armed_garbage"] += 1
            await send_garbage()
            assert int(dut.boot_sel_o.value) == 0, \
                f"block {blk}: garbage must never commit (seed {seed})"

        # poke the deaf loader: closed-state traffic must change nothing
        for _ in range(rng.randrange(1, 3)):
            kind = rng.choice(("good", "corrupt", "garbage", "idle"))
            if kind == "good":
                bins["closed_good"] += 1
                sel = int(dut.boot_sel_o.value)
                await send_good()
                assert int(dut.boot_sel_o.value) == sel, \
                    f"block {blk}: the deaf loader changed boot_sel (seed {seed})"
            elif kind == "corrupt":
                bins["closed_corrupt"] += 1
                await send_corrupt()
            elif kind == "garbage":
                bins["closed_garbage"] += 1
                await send_garbage()
            else:
                bins["idle"] += 1
                await ClockCycles(dut.clk, rng.randrange(500, 3000))
            if booted:
                assert await z_signature(dut), \
                    f"block {blk}: closed-state {kind} disturbed the program (seed {seed})"

    # the storm must END on a committed, speaking machine
    await repor(dut)
    await send_good()
    assert int(dut.boot_sel_o.value) == 1
    assert await z_signature(dut), f"final block: the die must end alive (seed {seed})"

    dut._log.info(f"TRAFFIC STORM: seed {seed}, blocks {N_BLOCKS}, "
                  f"bins {bins}, rejects {rejects[0]}")
    for k in ("armed_good", "armed_corrupt", "armed_garbage"):
        assert bins[k] >= 3, f"coverage hole: {k} only {bins[k]}"
    closed_total = (bins["closed_good"] + bins["closed_corrupt"]
                    + bins["closed_garbage"] + bins["idle"])
    assert closed_total >= 9, f"coverage hole: closed-state pokes only {closed_total}"
    assert rejects[0] >= 3
