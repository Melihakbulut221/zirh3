# =============================================================================
# ZIRH-3 - SPI through the whole die (Cycle 32)
#
# An ISP-loaded program brings up SPI0 on PORTA pins 4..7, asserts
# the chip select, clocks one full-duplex byte at a bench slave, and
# floods 'Z' iff the byte that came back is the one the slave serves.
# The bench slave is the block suite's own, wired through the lease.
# =============================================================================

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_spi import Slave
from test_top_fuzz import z_signature
from test_top_isp import (addi, andi, beq, bne, image, jal, lui, lw, start,
                          sw, uart_send)

# SPI0 at 0x7800 = lui 0x8 + addi -0x800 (the addi sign lesson, applied)
SPI_PROGRAM = [
    lui(5, 0x8), addi(5, 5, -0x800),
    addi(6, 0, 4),   sw(6, 5, 0x04),   # DIV = 4
    addi(6, 0, 9),   sw(6, 5, 0x00),   # CTRL = EN | CS
    addi(6, 0, 0xA6), sw(6, 5, 0x08),  # TXD -> go
    lw(7, 5, 0x10), andi(7, 7, 1), bne(7, 0, -8),   # poll TIP
    lw(7, 5, 0x0C),                    # RXD
    addi(9, 0, 0x5A),                  # expected
    lui(10, 0x2),
    addi(11, 0, 0x5A),
    beq(7, 9, 8),                      # match: keep Z
    addi(11, 0, 0x46),                 # mismatch: F
    sw(11, 10, 4),
    jal(0, -4),
]


@cocotb.test()
async def test_loaded_code_speaks_spi(dut):
    await start(dut, strap=1)

    slave = Slave()
    slave.serve = 0x5A
    slave.reset_frame()

    async def pins():
        while True:
            await RisingEdge(dut.clk)
            oe = int(dut.gpio_a_oe.value)
            o = int(dut.gpio_a_o.value)
            sck  = (o >> 4) & 1 if (oe >> 4) & 1 else 0
            mosi = (o >> 5) & 1 if (oe >> 5) & 1 else 0
            csn  = (o >> 7) & 1 if (oe >> 7) & 1 else 1
            slave.step(sck, mosi, csn)
            v = int(dut.gpio_a_i.value) & ~(1 << 6)
            dut.gpio_a_i.value = v | (slave.miso << 6)

    cocotb.start_soon(pins())

    for b in image(SPI_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "spi program must commit"
    assert await z_signature(dut), \
        "RXD mismatched - the program shouted something else"
    assert slave.bytes_seen == [0xA6], f"slave saw {slave.bytes_seen}"
    assert int(dut.gpio_a_oe.value) >> 18 & 0x1FF == 0, \
        "MCS clear: PORTA 18-26 still belong to the GPIO block"


# 12-bit word, CSSEL 1 under MCS: the select rides PORTA 18, the
# classic pin 7 stays HIGH - through the whole die
WIDE_PROGRAM = [
    lui(5, 0x8), addi(5, 5, -0x800),
    addi(6, 0, 4),    sw(6, 5, 0x04),          # DIV = 4
    addi(6, 0, 12),   sw(6, 5, 0x14),          # WLEN = 12
    addi(6, 0, 0x59), sw(6, 5, 0x00),          # CTRL = EN|CS|MCS|CSSEL1
    lui(6, 0x1), addi(6, 6, -0x5AD),           # 0xA53
    sw(6, 5, 0x08),                            # TXD -> go
    lw(7, 5, 0x10), andi(7, 7, 1), bne(7, 0, -8),   # poll TIP
    lw(7, 5, 0x0C),                            # RXD
    addi(9, 0, 0x5CA),                         # expected reply
    lui(10, 0x2),
    addi(11, 0, 0x5A),
    beq(7, 9, 8),                              # match: keep Z
    addi(11, 0, 0x46),                         # mismatch: F
    sw(11, 10, 4),
    jal(0, -4),
]


@cocotb.test()
async def test_loaded_code_speaks_wide_spi(dut):
    await start(dut, strap=1)

    slave = Slave(nbits=12)
    slave.serve = 0x5CA
    slave.reset_frame()
    classic_high = []

    async def pins():
        while True:
            await RisingEdge(dut.clk)
            oe = int(dut.gpio_a_oe.value)
            o = int(dut.gpio_a_o.value)
            sck  = (o >> 4) & 1 if (oe >> 4) & 1 else 0
            mosi = (o >> 5) & 1 if (oe >> 5) & 1 else 0
            # the burst's select is the EXTRA line on PORTA 18
            csn  = (o >> 18) & 1 if (oe >> 18) & 1 else 1
            if not csn and (oe >> 7) & 1:
                classic_high.append((o >> 7) & 1)
            slave.step(sck, mosi, csn)
            v = int(dut.gpio_a_i.value) & ~(1 << 6)
            dut.gpio_a_i.value = v | (slave.miso << 6)

    cocotb.start_soon(pins())

    for b in image(WIDE_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "wide-spi program must commit"
    assert await z_signature(dut), \
        "RXD mismatched - the program shouted something else"
    assert slave.bytes_seen == [0xA53], f"slave saw {slave.bytes_seen}"
    assert classic_high and all(classic_high), \
        "CSSEL 1 selected: the classic line must stay HIGH throughout"
