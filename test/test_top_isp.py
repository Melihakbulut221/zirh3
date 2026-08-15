# =============================================================================
# ZIRH-3 - the CPU-carrying top: ISP end to end (import ladder rung 3)
# test/test_top_isp.py
#
# The ZIRH-2 contract, re-proven on this die's own composition: stream a
# CRC32-sealed image over the UART pin, watch the loader commit it, and
# observe the LOADED program running - not by peeking at state, but by
# what it says on the TX pin. Then the negative: a corrupt image never
# runs and the golden ROM comes back instead. Firmware is data, so the
# testbench writes firmware (its own three-format assembler).
# =============================================================================

import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly

CLK_NS = 40
DIV = 20                     # RESET_DIV override in Makefile.top
MAGIC = 0x5A495248

UART_BASE = 0x2000           # slot 2
UART_STATUS = UART_BASE + 0x0
UART_TXDATA = UART_BASE + 0x4


def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def sw(rs2, rs1, off):
    return (((off >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0x2 << 12) | ((off & 0x1F) << 7) | 0x23


def jal(rd, off):
    imm = off & 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F


# the loaded program: shout 'Z' on the UART forever. t0 = UART base;
# the TX register swallows writes whenever ready, and a busy TX drops
# them - for this proof a visible 'Z' stream is all that matters.
PROGRAM = [
    lui(5, UART_BASE >> 12),     # t0 = 0x2000
    addi(6, 0, 0x5A),            # t1 = 'Z'
    sw(6, 5, 4),                 # UART_TXDATA = 'Z'
    jal(0, -4),                  # again, forever
]


def image(words, crc=None, magic=MAGIC):
    payload = b''.join(w.to_bytes(4, 'little') for w in words)
    c = zlib.crc32(payload) if crc is None else crc
    return (magic.to_bytes(4, 'little') + len(words).to_bytes(2, 'little')
            + (1).to_bytes(2, 'little') + c.to_bytes(4, 'little') + payload)


async def start(dut, strap):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.pwr_good_i.value = 1
    dut.boot_strap_i.value = strap
    dut.dbg_unlock_strap_i.value = 0
    dut.uart_rx_i.value = 1
    dut.tck_i.value = 0
    dut.tms_i.value = 0
    dut.tdi_i.value = 0
    dut.trst_n_i.value = 1
    dut.rst_n_pad.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst_n_pad.value = 1
    # POR settle (POR_CYCLES=16 in the makefile) + strap sampling
    await ClockCycles(dut.clk, 60)


async def uart_send(dut, value):
    await RisingEdge(dut.clk)
    bits = [0] + [(value >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        dut.uart_rx_i.value = b
        await ClockCycles(dut.clk, DIV)
    dut.uart_rx_i.value = 1
    await ClockCycles(dut.clk, 3 * DIV)


async def uart_capture(dut, timeout_cycles):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.uart_tx_o.value) == 0:
            break
    else:
        return None
    await ClockCycles(dut.clk, DIV // 2)
    bits = []
    for _ in range(9):
        await ClockCycles(dut.clk, DIV)
        await ReadOnly()
        bits.append(int(dut.uart_tx_o.value))
    if bits[8] != 1:
        return None
    return sum(b << i for i, b in enumerate(bits[:8]))


@cocotb.test()
async def test_isp_loads_and_the_program_speaks(dut):
    """Stream a valid image over the UART pin: the loader commits it,
    the CPU runs from the bank, and the LOADED program's 'Z' stream
    appears on the TX pin - arbitrary code, written after tape-out,
    audible from outside the die."""
    await start(dut, strap=1)

    for b in image(PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "valid image must commit"
    assert int(dut.evt_boot_reject_o.value) == 0

    # the loaded loop must speak: hunt for 'Z' on the pin
    for _ in range(40):
        b = await uart_capture(dut, 80_000)
        if b == 0x5A:
            break
    else:
        raise AssertionError("loaded program's 'Z' never reached the pin")


@cocotb.test()
async def test_corrupt_image_falls_back_to_rom(dut):
    """The same stream with a wrong CRC: refused at the read-back
    boundary, bank never selected, and the golden ROM firmware boots
    instead - proven by its echo answering on the pins."""
    await start(dut, strap=1)

    for b in image(PROGRAM, crc=0xDEADBEEF):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 0, "corrupt image must never run"

    # ROM fallback: give the bit-serial CPU its boot time, then echo
    await ClockCycles(dut.clk, 240_000)
    await uart_send(dut, 0x41)
    for _ in range(40):
        b = await uart_capture(dut, 80_000)
        if b == 0x42:
            break
    else:
        raise AssertionError("ROM fallback never echoed after reject")


@cocotb.test()
async def test_golden_strap_is_yesterdays_chip(dut):
    """Strap low: no loader, ROM boot, the imported cluster behaves as
    its own suite proved - echo b+1 through the pins."""
    await start(dut, strap=0)

    await ClockCycles(dut.clk, 240_000)
    await uart_send(dut, 0x41)
    for _ in range(40):
        b = await uart_capture(dut, 80_000)
        if b == 0x42:
            break
    else:
        raise AssertionError("golden-strap ROM echo never appeared")
