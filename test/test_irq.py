# =============================================================================
# ZIRH-3 - interrupt fabric block suite (Cycle 34)
#
# The fabric at its own boundary: RAW is the world as it is, MASK is
# the one register software owns, PENDING is their AND and nothing
# else. No latch anywhere - a source that drops out of RAW drops out
# of PENDING the same cycle, because every flag is sticky at its own
# peripheral and a fabric that latched would double-book it. TMR
# silent throughout.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

MASK, RAW, PENDING = 0x00, 0x04, 0x08


async def bring_up(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.we_i.value = 0
    dut.raw_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def bus_write(dut, adr, dat):
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.dat_i.value = dat
    dut.we_i.value = 1
    await ClockCycles(dut.clk, 2)
    dut.cyc_i.value = 0
    dut.we_i.value = 0
    await ClockCycles(dut.clk, 1)


async def bus_read(dut, adr):
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.we_i.value = 0
    await ClockCycles(dut.clk, 2)
    v = int(dut.rdt_o.value)
    dut.cyc_i.value = 0
    await ClockCycles(dut.clk, 1)
    return v


@cocotb.test()
async def test_reset_masks_everything(dut):
    await bring_up(dut)
    dut.raw_i.value = 0xFFFFFFFF
    await ClockCycles(dut.clk, 2)
    assert await bus_read(dut, MASK) == 0, "mask must reset clear"
    assert await bus_read(dut, RAW) == 0xFFFFFFFF, "raw must be the wire"
    assert await bus_read(dut, PENDING) == 0, "nothing unmasked, nothing pending"
    assert int(dut.pending_o.value) == 0, "the core must see silence"
    assert int(dut.err_o.value) == 0


@cocotb.test()
async def test_pending_is_raw_and_mask(dut):
    await bring_up(dut)
    await bus_write(dut, MASK, 0x00FF00FF)
    assert await bus_read(dut, MASK) == 0x00FF00FF, "mask readback"
    dut.raw_i.value = 0x0F0F0F0F
    await ClockCycles(dut.clk, 2)
    assert await bus_read(dut, PENDING) == 0x000F000F, "AND, nothing else"
    assert int(dut.pending_o.value) == 0x000F000F, "port and word agree"
    assert int(dut.err_o.value) == 0


@cocotb.test()
async def test_no_latch_a_dropped_source_drops(dut):
    await bring_up(dut)
    await bus_write(dut, MASK, 0xFFFFFFFF)
    dut.raw_i.value = 1 << 24
    await ClockCycles(dut.clk, 2)
    assert int(dut.pending_o.value) == 1 << 24
    dut.raw_i.value = 0
    await ClockCycles(dut.clk, 2)
    assert int(dut.pending_o.value) == 0, \
        "the fabric must not remember what the peripheral cleared"
    assert int(dut.err_o.value) == 0


@cocotb.test()
async def test_mask_write_is_once_per_strobe(dut):
    await bring_up(dut)
    # hold the write for many cycles: the wr_seen idiom must land it once
    dut.cyc_i.value = 1
    dut.adr_i.value = MASK
    dut.dat_i.value = 0x12345678
    dut.we_i.value = 1
    await ClockCycles(dut.clk, 6)
    dut.dat_i.value = 0xDEADBEEF          # late data must NOT re-land
    await ClockCycles(dut.clk, 3)
    dut.cyc_i.value = 0
    dut.we_i.value = 0
    await ClockCycles(dut.clk, 1)
    assert await bus_read(dut, MASK) == 0x12345678, \
        "a held strobe writes exactly once"
    assert int(dut.err_o.value) == 0
