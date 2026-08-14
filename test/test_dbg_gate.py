# ZIRH P2 - the debug gate: locked means inert, and stays that way.
import random

import cocotb
import fsm_cov
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, NextTimeStep, ReadOnly, RisingEdge


async def por(dut, strap):
    dut.dm_debug_req_i.value = 0
    dut.dm_ndmreset_i.value = 0
    dut.dm_sba_cyc_i.value = 0
    dut.dm_sba_adr_i.value = 0
    dut.dm_sba_dat_i.value = 0
    dut.dm_sba_we_i.value = 0
    dut.unlock_strap_i.value = strap
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def hammer(dut, cycles=200):
    """Drive random debug-side garbage; return OR of system outputs."""
    leaked = 0
    for _ in range(cycles):
        await NextTimeStep()
        dut.dm_debug_req_i.value = random.getrandbits(1)
        dut.dm_ndmreset_i.value = random.getrandbits(1)
        dut.dm_sba_cyc_i.value = random.getrandbits(1)
        dut.dm_sba_we_i.value = random.getrandbits(1)
        dut.dm_sba_adr_i.value = random.getrandbits(32)
        dut.dm_sba_dat_i.value = random.getrandbits(32)
        await RisingEdge(dut.clk)
        await ReadOnly()
        leaked |= int(dut.debug_req_o.value) | int(dut.ndmreset_o.value)
        leaked |= int(dut.sba_cyc_o.value) | int(dut.sba_we_o.value)
        leaked |= int(dut.sba_adr_o.value) | int(dut.sba_dat_o.value)
    await NextTimeStep()
    return leaked


@cocotb.test()
async def test_dbg_gate(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    _cov = fsm_cov.watch(dut, dut.u_st.q_o, "dbg")
    random.seed(1453)

    # flight: strap low at POR - everything inert under full hammering
    await por(dut, 0)
    await ReadOnly()
    assert int(dut.locked_o.value) == 1
    await NextTimeStep()
    assert await hammer(dut) == 0, "locked gate leaked a signal"

    # wiggling the strap after reset must change nothing
    await NextTimeStep()
    dut.unlock_strap_i.value = 1
    await ClockCycles(dut.clk, 10)
    await ReadOnly()
    assert int(dut.locked_o.value) == 1, "post-reset strap unlocked the gate"
    await NextTimeStep()
    assert await hammer(dut) == 0, "post-reset strap wiggle leaked"

    # bench: strap high at POR - signals pass verbatim
    await por(dut, 1)
    await ReadOnly()
    assert int(dut.locked_o.value) == 0
    await NextTimeStep()
    dut.dm_debug_req_i.value = 1
    dut.dm_sba_cyc_i.value = 1
    dut.dm_sba_adr_i.value = 0x12345678
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.debug_req_o.value) == 1
    assert int(dut.sba_adr_o.value) == 0x12345678
    await NextTimeStep()

    # and dropping the strap mid-run must NOT lock an open gate either
    # (the latch is one-way in BOTH directions: sampled once, then dead)
    dut.unlock_strap_i.value = 0
    await ClockCycles(dut.clk, 10)
    await ReadOnly()
    assert int(dut.locked_o.value) == 0, "open gate must ignore the strap too"
    await NextTimeStep()

    fsm_cov.dump("dbg", _cov)
    dut._log.info("dbg gate: flight lock inert under hammering, strap "
                  "dead after POR both ways, bench passthrough exact")
