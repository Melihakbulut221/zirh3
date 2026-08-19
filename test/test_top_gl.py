# =============================================================================
# ZIRH-3 - gate-level wound tests (Cycle 19)
#
# Runs ONLY against the stitched gate netlist (scripts/gl_boot.sh): the
# stitcher publishes every replica as tmrA_<i>/tmrB_<i>/tmrC_<i> nets
# and GL_TMR_N carries the flop count into this bench.
#
# Proof-of-life discipline: the loaded program FLOODS the pin with 'Z'
# back to back, but the telemetry engine free-runs (en_i tied high) and
# its frame header also opens with 0x5A - a single captured 0x5A proves
# nothing. Three consecutive 0x5A do: a frame follows its sync with
# 0x33 and falls silent for 2^INTERVAL_LOG2 cycles, the flood does not.
#
# Two scenarios:
#   wound   - replica rail B of EVERY flop forced wrong from before
#             reset through the whole boot; the vote must carry the
#             machine, the release must heal every replica, and the
#             flood must continue. Harsher than any single-event upset.
#   control - rails B AND C forced: the majority now lies, every voter
#             is pinned, and the machine MUST fall silent. This is the
#             test of the test - it proves the forces reach the state
#             and that the flood genuinely requires a living core.
# =============================================================================

import os

import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from test_top_isp import (PROGRAM, hunt_z_flood, image, start, uart_send)


def rails(dut, name, n):
    core = dut.u_soc.u_cpu
    return [core._id(f"tmr{name}_{i}", extended=False) for i in range(n)]


@cocotb.test()
async def test_gl_core_floods(dut):
    """No wound: the gate netlist must flood the pin on its own. This
    is the honest form of the boot proof - a lone 0x5A is telemetry."""
    await start(dut, strap=1)
    for b in image(PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)
    assert int(dut.boot_sel_o.value) == 1
    assert int(dut.evt_boot_reject_o.value) == 0
    assert await hunt_z_flood(dut, 40), "clean GL boot: the flood never came"


@cocotb.test()
async def test_boot_survives_a_dead_replica_rail(dut):
    n = int(os.environ["GL_TMR_N"])
    rail_a = rails(dut, "A", n)
    rail_b = rails(dut, "B", n)

    # the wound precedes the reset: rail B is already lying when POR fires
    for sig in rail_b:
        sig.value = Force(1)

    await start(dut, strap=1)
    for b in image(PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "wounded boot: image must commit"
    assert int(dut.evt_boot_reject_o.value) == 0

    # the wound must be real: a healthy machine under a forced rail
    # shows live disagreement between A and B - if it does not, the
    # forces never reached the state and this proof is hollow
    bitten = sum(1 for a, b in zip(rail_a, rail_b)
                 if str(a.value) != str(b.value))
    assert bitten > 0, "rail B agrees with rail A under force - wound is fake"

    assert await hunt_z_flood(dut, 40), "wounded boot: the flood never came"

    # release the rail: every replica must rejoin its voted word
    # (uart_capture returns from a ReadOnly phase - realign before writing)
    await ClockCycles(dut.clk, 1)
    for sig in rail_b:
        sig.value = Release()
    await ClockCycles(dut.clk, 20)

    stragglers = sum(1 for a, b in zip(rail_a, rail_b)
                     if str(a.value) != str(b.value))
    assert stragglers == 0, f"{stragglers}/{n} replicas never rejoined"

    assert await hunt_z_flood(dut, 40), "post-heal: the program went silent"


@cocotb.test()
async def test_majority_wound_kills_the_machine(dut):
    n = int(os.environ["GL_TMR_N"])

    # two rails lie: the vote is now pinned high in every flop
    for sig in rails(dut, "B", n) + rails(dut, "C", n):
        sig.value = Force(1)

    await start(dut, strap=1)
    for b in image(PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    # the loader is RTL and may still commit; the CORE must be dead -
    # telemetry frames keep arriving (they need no CPU), the flood must not
    assert not await hunt_z_flood(dut, 12), \
        "majority-wounded core still speaks - the vote is not load-bearing"
