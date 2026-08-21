# =============================================================================
# ZIRH-3 - I2C through the whole die (Cycle 31)
#
# An ISP-loaded program brings up I2C0, sends START + one address
# byte to whatever sits on PORTA pins 0/1, polls TIP down, and
# floods 'Z' if the slave ACKed. The bench IS that slave - the same
# model the block suite proved, wired to the pins through the
# open-drain convention: the wire is the AND of every pull.
# =============================================================================

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_i2c import Slave
from test_top_fuzz import z_signature
from test_top_isp import (addi, andi, beq, bne, image, jal, lui, lw, start,
                          sw, uart_send)

I2C0 = 0x6800

# enable, DIV=8, TXD=0xA6, CMD=STA|WR, poll TIP, check rxack==0,
# flood 'Z' on ACK / 'F' on NACK
I2C_PROGRAM = [
    lui(5, 0x7), addi(5, 5, -0x800),    # t0 = 0x7000 - 0x800 = 0x6800
    # (0x800 as a 12-bit addi immediate is NEGATIVE - the sign bit
    #  cost this bench one debugging session; build down from 0x7000)
    addi(6, 0, 1),  sw(6, 5, 0x00),     # CTRL en
    addi(6, 0, 8),  sw(6, 5, 0x04),     # DIV
    addi(6, 0, 0xA6), sw(6, 5, 0x0C),   # TXD
    addi(6, 0, 0x5), sw(6, 5, 0x08),    # CMD = STA|WR
    # poll: t2 = STAT; loop while TIP
    lw(7, 5, 0x14), andi(7, 7, 1), bne(7, 0, -8),
    lw(7, 5, 0x14), andi(7, 7, 2),      # rxack
    lui(10, 0x2),                       # uart
    addi(11, 0, 0x5A),
    beq(7, 0, 8),                       # ACK: keep Z
    addi(11, 0, 0x46),                  # NACK: F
    sw(11, 10, 4),
    jal(0, -4),
]


@cocotb.test()
async def test_loaded_code_speaks_i2c(dut):
    await start(dut, strap=1)

    slave = Slave()

    async def pins():
        while True:
            await RisingEdge(dut.clk)
            oe = int(dut.gpio_a_oe.value)
            scl = 0 if ((oe & 1) or slave.scl_pull) else 1
            sda = 0 if ((oe & 2) or slave.sda_pull) else 1
            v = int(dut.gpio_a_i.value) & ~0x3
            dut.gpio_a_i.value = v | (sda << 1) | scl
            slave.step(scl, sda)

    cocotb.start_soon(pins())

    for b in image(I2C_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "i2c program must commit"
    assert await z_signature(dut), \
        "slave never ACKed - the program shouted something else"
    assert "START" in slave.events, "the slave must have seen a START"
    assert slave.bytes_seen == [0xA6], f"slave saw {slave.bytes_seen}"
