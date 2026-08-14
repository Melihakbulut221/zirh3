# ZIRH P2 - the QSPI controller: raw reads both widths, backpressure,
# abort, and the crown: a full boot from behavioral MRAM into the
# SECDED SRAM through the boot controller.
import random
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, NextTimeStep, ReadOnly, RisingEdge


def image(words, version=1):
    payload = b''.join(w.to_bytes(4, 'little') for w in words)
    hdr = ((0x5A495248).to_bytes(4, 'little')
           + len(words).to_bytes(2, 'little')
           + version.to_bytes(2, 'little')
           + zlib.crc32(payload).to_bytes(4, 'little'))
    return hdr + payload


async def por(dut, strap=0, use_boot=0):
    dut.start_i.value = 0
    dut.quad_i.value = 0
    dut.addr_i.value = 0
    dut.len_i.value = 0
    dut.abort_i.value = 0
    dut.tap_ready_i.value = 0
    dut.use_boot_i.value = use_boot
    dut.strap_i.value = strap
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


def load_mram(dut, blob, base=0):
    for i, b in enumerate(blob):
        dut.u_mram.mem[base + i].value = b


async def kick(dut, addr, length, quad):
    await NextTimeStep()
    dut.addr_i.value = addr
    dut.len_i.value = length
    dut.quad_i.value = quad
    dut.start_i.value = 1
    await ClockCycles(dut.clk, 2)
    await NextTimeStep()
    dut.start_i.value = 0


async def tap_read(dut, n, stall=0.0):
    got = []
    while len(got) < n:
        await NextTimeStep()
        dut.tap_ready_i.value = 0 if random.random() < stall else 1
        await ReadOnly()
        take = (int(dut.tap_valid_o.value) == 1
                and int(dut.tap_ready_i.value) == 1)
        d = int(dut.tap_data_o.value) if take else None
        await RisingEdge(dut.clk)
        if take:
            got.append(d)
    await NextTimeStep()
    dut.tap_ready_i.value = 0
    return bytes(got)


@cocotb.test()
async def test_qspi_mram(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    random.seed(1923)

    blob = bytes(random.getrandbits(8) for _ in range(64))

    # x1 read, no stalls
    await por(dut)
    load_mram(dut, blob)
    await kick(dut, 0, 32, quad=0)
    got = await tap_read(dut, 32)
    assert got == blob[:32], f"x1: {got.hex()} != {blob[:32].hex()}"

    # x1 read with heavy backpressure - sck freeze must lose nothing
    await kick(dut, 8, 24, quad=0)
    got = await tap_read(dut, 24, stall=0.7)
    assert got == blob[8:32], "x1 with stalls corrupted the stream"

    # x4 quad read
    await kick(dut, 0, 32, quad=1)
    got = await tap_read(dut, 32)
    assert got == blob[:32], f"x4: {got.hex()} != {blob[:32].hex()}"

    # abort releases the bus
    await kick(dut, 0, 64, quad=0)
    await ClockCycles(dut.clk, 40)
    await NextTimeStep()
    dut.abort_i.value = 1
    await ClockCycles(dut.clk, 2)
    await NextTimeStep()
    dut.abort_i.value = 0
    await ClockCycles(dut.clk, 2)
    await ReadOnly()
    assert int(dut.busy_o.value) == 0, "abort did not stop the transfer"
    assert int(dut.u_qspi.cs_n_o.value) == 1, "abort did not release CS"
    await NextTimeStep()

    # the crown: boot from MRAM - image at 0x100, streamed by the
    # controller, verified and committed by the boot controller into
    # the five-macro SECDED SRAM
    words = [random.getrandbits(32) for _ in range(48)]
    img = image(words)
    await por(dut, strap=0b01, use_boot=1)
    load_mram(dut, img, base=0x100)
    await kick(dut, 0x100, len(img), quad=1)
    for _ in range(200_000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.evt_accept_o.value) or int(dut.evt_reject_o.value):
            acc = int(dut.evt_accept_o.value)
            break
        await NextTimeStep()
    else:
        raise AssertionError("boot never concluded")
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert acc == 1, "MRAM image was rejected"
    assert int(dut.boot_sel_o.value) == 1 and int(dut.bank_o.value) == 0
    await NextTimeStep()

    dut._log.info("qspi: x1, x1-stalled, x4, abort, and a full boot "
                  "from MRAM into the SECDED SRAM - all good")
