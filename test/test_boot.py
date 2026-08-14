# ZIRH P2 - boot controller suite: the BOOT.md claims, proven.
import random
import zlib

import cocotb
import fsm_cov
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, NextTimeStep, ReadOnly, RisingEdge


def image(words, version=1, magic=0x5A495248, crc=None):
    payload = b''.join(w.to_bytes(4, 'little') for w in words)
    c = zlib.crc32(payload) if crc is None else crc
    hdr = (magic.to_bytes(4, 'little') + len(words).to_bytes(2, 'little')
           + version.to_bytes(2, 'little') + c.to_bytes(4, 'little'))
    return hdr + payload


async def por(dut, strap):
    dut.st_valid_i.value = 0
    dut.st_data_i.value = 0
    dut.sig_ok_i.value = 1
    dut.signon_i.value = 0
    dut.wd_fail_i.value = 0
    dut.strap_i.value = strap
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def stream(dut, blob, tag='?', timeout=200_000):
    """Feed bytes with ready/valid; count accept/reject pulses seen."""
    acc = rej = 0
    i = 0
    while i < len(blob):
        await NextTimeStep()
        dut.st_valid_i.value = 1
        dut.st_data_i.value = blob[i]
        await ReadOnly()
        took = int(dut.st_ready_o.value) == 1
        acc += int(dut.evt_accept_o.value)
        rej += int(dut.evt_reject_o.value)
        await RisingEdge(dut.clk)
        if took:
            i += 1
        if acc or rej:
            break               # the DUT has ruled; stop force-feeding
        timeout -= 1
        if timeout <= 0:
            st = int(dut.u_boot.state_q.value)
            bc = int(dut.u_boot.bcnt_q.value)
            ix = int(dut.u_boot.idx_q.value)
            raise AssertionError(
                f"stream[{tag}] stalled at byte {i}: state={st} bcnt={bc} idx={ix}")
    await NextTimeStep()
    dut.st_valid_i.value = 0
    # drain: let the verify pass finish
    for _ in range(30_000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        acc += int(dut.evt_accept_o.value)
        rej += int(dut.evt_reject_o.value)
        if acc or rej:
            break
    await RisingEdge(dut.clk)   # let the commit/reject edge land
    await NextTimeStep()
    return acc, rej


async def pulse(dut, sig):
    await NextTimeStep()
    sig.value = 1
    await RisingEdge(dut.clk)
    await NextTimeStep()
    sig.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_boot_contract(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    _cov = fsm_cov.watch(dut, dut.u_boot.state_q, "boot")

    random.seed(2027)

    # --- 1. good image on strap A: accept, run from SRAM bank A ----------
    await por(dut, 0b01)
    w = [random.getrandbits(32) for _ in range(64)]
    acc, rej = await stream(dut, image(w), 'S1')
    assert acc == 1 and rej == 0, f"good image: acc={acc} rej={rej}"
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 1 and int(dut.bank_o.value) == 0
    await NextTimeStep()

    # --- 2. corrupt CRC: reject, fall back to golden ---------------------
    await por(dut, 0b01)
    acc, rej = await stream(dut, image(w, crc=0xDEADBEEF), 'S2')
    assert acc == 0 and rej == 1, f"bad crc: acc={acc} rej={rej}"
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 0, "bad image must fall to golden"
    await NextTimeStep()

    # --- 3. bad magic: reject at the header --------------------------------
    await por(dut, 0b10)
    acc, rej = await stream(dut, image(w, magic=0x11111111), 'S3')
    assert acc == 0 and rej == 1
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 0
    await NextTimeStep()

    # --- 4. golden strap loads nothing ------------------------------------
    await por(dut, 0b00)
    await ClockCycles(dut.clk, 50)
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 0
    assert int(dut.st_ready_o.value) == 0, "golden must not consume bytes"
    await NextTimeStep()

    # --- 5. interrupted load never yields a bootable bank ------------------
    await por(dut, 0b01)
    blob = image(w)
    half = blob[:len(blob) // 2]
    i = 0
    while i < len(half):
        await NextTimeStep()
        dut.st_valid_i.value = 1
        dut.st_data_i.value = half[i]
        await ReadOnly()
        took = int(dut.st_ready_o.value) == 1
        await RisingEdge(dut.clk)
        if took:
            i += 1
    await NextTimeStep()
    dut.st_valid_i.value = 0
    await ClockCycles(dut.clk, 200)
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 0, "half-load must not boot"
    await NextTimeStep()

    # --- 6. the ISP path and the watchdog revert ladder -------------------
    # host strap: first image -> inactive bank (B, since pref reset A);
    # second image while running -> the now-inactive A; wd_fail without
    # signon reverts B; second wd_fail lands golden
    await por(dut, 0b11)
    wa = [random.getrandbits(32) for _ in range(32)]
    acc, rej = await stream(dut, image(wa, version=2), 'S6a')
    assert acc == 1, "host image 1 must commit"
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 1 and int(dut.bank_o.value) == 1
    await NextTimeStep()

    wb = [random.getrandbits(32) for _ in range(32)]
    acc, rej = await stream(dut, image(wb, version=3), 'S6b')
    assert acc == 1, "ISP image 2 must commit"
    await ReadOnly()
    assert int(dut.bank_o.value) == 0, "ISP flips to the fresh bank"
    await NextTimeStep()

    await pulse(dut, dut.wd_fail_i)
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 1 and int(dut.bank_o.value) == 1, (
        "first failure must revert to the other valid bank")
    await NextTimeStep()

    await pulse(dut, dut.wd_fail_i)
    await ReadOnly()
    assert int(dut.boot_sel_o.value) == 0, (
        "second failure must land on the golden ROM")
    await NextTimeStep()

    fsm_cov.dump("boot", _cov)
    dut._log.info("boot: accept/reject/fallback, golden strap, "
                  "interruption tolerance, ISP double-bank and the "
                  "watchdog revert ladder all good")
