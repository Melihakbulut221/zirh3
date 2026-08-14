# ZIRH-2 program P1 - the sliced 39-bit SRAM word: SECDED behaviour
# proven on the macro-backed storage, corruption injected by poking
# the behavioral macro arrays directly.
import random

import cocotb
import fsm_cov
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, NextTimeStep, ReadOnly, RisingEdge


async def bus(dut, adr, we=0, dat=0, sel=0xF, timeout=16):
    await NextTimeStep()
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.we_i.value = we
    dut.dat_i.value = dat
    dut.sel_i.value = sel
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.ack_o.value) == 1:
            v = dut.rdt_o.value
            rdt = int(v) if v.is_resolvable else None
            corr = int(dut.evt_corr_o.value)
            unc = int(dut.evt_uncorr_o.value)
            await NextTimeStep()
            dut.cyc_i.value = 0
            await RisingEdge(dut.clk)
            return rdt, corr, unc
    raise AssertionError(f"no ack at adr {adr:#x}")


def slice_mem(dut, k):
    m = dut._id(f"g_slice[{k}]", extended=False).u_m
    return m.u_macro.i_SRAM_1P_behavioral_bm_bist.memory


async def flip_stored_bit(dut, widx, bitpos):
    """Flip stored codeword bit (0..38) of word widx inside the macros."""
    k, b = bitpos // 8, bitpos % 8
    if bitpos >= 32:
        k, b = 4, bitpos - 32
    mem = slice_mem(dut, k)
    cur = int(mem[widx].value)
    mem[widx].value = cur ^ (1 << b)
    await NextTimeStep()


@cocotb.test()
async def test_sram39_secded(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    _cov = fsm_cov.watch(dut, dut.state, "sram39")
    dut.cyc_i.value = 0
    dut.scrub_en_i.value = 0
    dut.bist_start_i.value = 0
    dut.bist_mode_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    random.seed(1907)

    # boot discipline: zero-fill the whole array first (the background
    # sweep decodes every row; uninitialized rows are X only in
    # simulation, but the doctrine is real - firmware zero-fills at boot)
    words = {}
    for a in range(1024):
        words[a] = random.getrandbits(32)
        await bus(dut, a << 2, we=1, dat=words[a])
    dut.scrub_en_i.value = 1   # boot init done - release the sweep

    for a, w in words.items():
        rdt, corr, unc = await bus(dut, a << 2)
        assert rdt == w and corr == 0 and unc == 0, f"roundtrip a={a}"

    # single-bit corruption in EVERY slice: corrected + scrubbed
    for bitpos in (0, 7, 8, 15, 21, 31, 32, 38):
        rdt, corr, unc = await bus(dut, 17 << 2)
        assert corr == 0, "precondition dirty"
        await flip_stored_bit(dut, 17, bitpos)
        rdt, corr, unc = await bus(dut, 17 << 2)
        assert rdt == words[17], f"bit {bitpos}: data corrupted through ECC"
        assert corr == 1 and unc == 0, f"bit {bitpos}: events {corr},{unc}"
        rdt, corr, unc = await bus(dut, 17 << 2)
        assert corr == 0, f"bit {bitpos}: scrub did not clean the word"

    # double-bit: detected uncorrectable
    await flip_stored_bit(dut, 511, 3)
    await flip_stored_bit(dut, 511, 27)
    rdt, corr, unc = await bus(dut, 511 << 2)
    assert unc == 1 and corr == 0, f"double-bit events {corr},{unc}"
    # heal it for the next phase
    await bus(dut, 511 << 2, we=1, dat=words[511])

    # partial write under corruption: corrected old bytes merge with new
    await flip_stored_bit(dut, 1023, 12)
    await bus(dut, 1023 << 2, we=1, dat=0x000000EE, sel=0x1)
    rdt, corr, unc = await bus(dut, 1023 << 2)
    exp = (words[1023] & 0xFFFFFF00) | 0xEE
    assert rdt == exp, f"merge under corruption: {rdt:#x} != {exp:#x}"

    # background scrubber: corrupt a word firmware never reads, give the
    # sweep one full pass of idle time, and the word must come back clean
    # with the repair reported on the scrub counter, not the read counter
    scrub_seen = [0]

    async def scrub_watch():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.evt_scrub_corr_o.value) == 1:
                scrub_seen[0] += 1
    cocotb.start_soon(scrub_watch())

    await flip_stored_bit(dut, 0, 5)
    await ClockCycles(dut.clk, 8 * 1024 + 200)   # one full sweep at DIV=8
    assert scrub_seen[0] >= 1, "the sweep never repaired anything"
    rdt, corr, unc = await bus(dut, 0 << 2)
    assert rdt == words[0] and corr == 0, (
        f"scrubber left the word dirty: corr={corr}")

    # address-in-ECC: move a stored word to the wrong row (the write-path
    # address SET) - the read must flag UNCORRECTABLE, never clean data
    src_w, dst_w = 17, 18
    for k in range(5):
        mem = slice_mem(dut, k)
        mem[dst_w].value = int(mem[src_w].value)
    await NextTimeStep()
    rdt, corr, unc = await bus(dut, dst_w << 2)
    assert unc == 1 and corr == 0, (
        f"wrong-row data not flagged: corr={corr} unc={unc}")

    fsm_cov.dump("sram39", _cov)
    dut._log.info("sram39: roundtrip, per-slice correction, scrub-on-read, "
                  "double-bit detection, corrupted-merge, background "
                  "scrubber heal, wrong-row detection all good")
