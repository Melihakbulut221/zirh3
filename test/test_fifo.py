# =============================================================================
# ZIRH-3 - TMR'd FIFO primitive block suite (Cycle 35)
#
# The queue at its own boundary: order preserved through fill and
# drain, refusal at both walls (a push to a full queue and a pop
# from an empty one change NOTHING), the level gauge exact at every
# step, wraparound clean across many times the depth, TMR silent
# throughout. A model runs alongside the whole time - the FIFO is
# only right if it is right at every step, not just at the ends.
# =============================================================================

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge


async def bring_up(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.wr_i.value = 0
    dut.rd_i.value = 0
    dut.wdat_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


# strobes are driven from the FALLING edge: half a period of margin
# on both sides of the rising edge that samples them, immune to the
# write-phase subtleties a one-cycle ClockCycles pulse can hit
async def push(dut, val):
    await FallingEdge(dut.clk)
    dut.wr_i.value = 1
    dut.wdat_i.value = val
    await FallingEdge(dut.clk)
    dut.wr_i.value = 0


async def pop(dut):
    await FallingEdge(dut.clk)
    v = int(dut.rdat_o.value)
    dut.rd_i.value = 1
    await FallingEdge(dut.clk)
    dut.rd_i.value = 0
    return v


@cocotb.test()
async def test_order_and_the_walls(dut):
    await bring_up(dut)
    assert int(dut.empty_o.value) == 1 and int(dut.full_o.value) == 0
    assert int(dut.level_o.value) == 0

    # fill to the brim, order in
    for i in range(16):
        assert int(dut.full_o.value) == 0
        await push(dut, 0x80 + i)
        assert int(dut.level_o.value) == i + 1
    assert int(dut.full_o.value) == 1

    # the seventeenth push is REFUSED: nothing moves
    await push(dut, 0xEE)
    assert int(dut.level_o.value) == 16, "a full queue refuses"
    assert int(dut.rdat_o.value) == 0x80, "the head is untouched"

    # drain, order out, the refused byte never appears
    for i in range(16):
        assert await pop(dut) == 0x80 + i
        assert int(dut.level_o.value) == 15 - i
    assert int(dut.empty_o.value) == 1

    # the pop from empty is refused the same way
    await FallingEdge(dut.clk)
    dut.rd_i.value = 1
    await FallingEdge(dut.clk)
    dut.rd_i.value = 0
    assert int(dut.level_o.value) == 0 and int(dut.empty_o.value) == 1

    assert int(dut.err_o.value) == 0
    print("FIFO walls: PASS")


@cocotb.test()
async def test_wraparound_against_a_model(dut):
    await bring_up(dut)
    rng = random.Random(35)
    model = []
    seq = 0
    for _ in range(600):                      # many times around the ring
        if rng.random() < 0.55 and len(model) < 16:
            await push(dut, seq & 0xFF)
            model.append(seq & 0xFF)
            seq += 1
        elif model:
            assert await pop(dut) == model.pop(0), "order broke mid-ring"
        assert int(dut.level_o.value) == len(model), "gauge drifted"
    while model:
        assert await pop(dut) == model.pop(0)
    assert int(dut.empty_o.value) == 1
    assert int(dut.err_o.value) == 0
    print("FIFO ring: PASS")


@cocotb.test()
async def test_simultaneous_push_pop_keeps_level(dut):
    await bring_up(dut)
    for i in range(4):
        await push(dut, i)
    # push and pop the same cycle: level holds, order holds
    await FallingEdge(dut.clk)
    dut.wr_i.value = 1
    dut.wdat_i.value = 0x55
    dut.rd_i.value = 1
    head = int(dut.rdat_o.value)
    await FallingEdge(dut.clk)
    dut.wr_i.value = 0
    dut.rd_i.value = 0
    assert head == 0, "head was the oldest"
    assert int(dut.level_o.value) == 4, "same-cycle push+pop is level-neutral"
    for want in (1, 2, 3, 0x55):
        assert await pop(dut) == want
    assert int(dut.err_o.value) == 0
    print("FIFO same-cycle: PASS")


@cocotb.test()
async def test_simultaneous_at_the_walls(dut):
    await bring_up(dut)

    # at FULL: the pop is accepted, the push is still refused - full
    # is judged BEFORE the edge, a same-cycle drain does not buy the
    # newcomer a slot
    for i in range(16):
        await push(dut, i)
    await FallingEdge(dut.clk)
    dut.wr_i.value = 1
    dut.wdat_i.value = 0xEE
    dut.rd_i.value = 1
    await FallingEdge(dut.clk)
    dut.wr_i.value = 0
    dut.rd_i.value = 0
    assert int(dut.level_o.value) == 15, "pop landed, push was refused"
    for want in range(1, 16):
        assert await pop(dut) == want, "the refused 0xEE never entered"
    assert int(dut.empty_o.value) == 1

    # at EMPTY: the push is accepted, the pop is refused the same way
    await FallingEdge(dut.clk)
    dut.wr_i.value = 1
    dut.wdat_i.value = 0x77
    dut.rd_i.value = 1
    await FallingEdge(dut.clk)
    dut.wr_i.value = 0
    dut.rd_i.value = 0
    assert int(dut.level_o.value) == 1, "push landed, pop was refused"
    assert await pop(dut) == 0x77

    assert int(dut.err_o.value) == 0
    print("FIFO wall strobes: PASS")
