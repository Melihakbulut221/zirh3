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


# --- Cycle 37: the slave chair through the whole die --------------------
# The program sits i2c1 down as slave 0x42 with a byte preloaded;
# the BENCH is the master on PORTA 2/3 - it writes 0x55, repeated-
# starts, reads the preload back. The program polls its own queue
# and floods the verdict on what the bench wrote.
I2C1 = 0x6C00
HALF = 24


def wire_bit(dut, pin, drive):
    oe = (int(dut.gpio_a_oe.value) >> pin) & 1
    o = (int(dut.gpio_a_o.value) >> pin) & 1
    die_pull = oe and not o
    return 0 if (die_pull or not drive) else 1


SLAVE_PROGRAM = [
    lui(5, 0x7), addi(5, 5, -0x400),           # t0 = 0x6C00
    addi(6, 0, 0xC2), sw(6, 5, 0x18),          # SADR = en | 0x42
    addi(6, 0, 0x3C), sw(6, 5, 0x24),          # STXD preload
    lw(7, 5, 0x1C), andi(7, 7, 2), beq(7, 0, -8),   # poll rx_valid
    lw(7, 5, 0x20),                            # SRXD
    addi(9, 0, 0x55),
    lui(10, 0x2),
    addi(11, 0, 0x5A),
    beq(7, 9, 8),
    addi(11, 0, 0x46),
    sw(11, 10, 4),
    jal(0, -4),
]


@cocotb.test()
async def test_the_die_answers_as_a_slave(dut):
    await start(dut, strap=1)

    m = {"scl": 1, "sda": 1}

    async def settle(n=HALF):
        for _ in range(n):
            v = int(dut.gpio_a_i.value)
            v = (v & ~0b1100) \
                | (wire_bit(dut, 2, m["scl"]) << 2) \
                | (wire_bit(dut, 3, m["sda"]) << 3)
            dut.gpio_a_i.value = v
            await ClockCycles(dut.clk, 1)

    async def bit_out(b):
        m["scl"] = 0; m["sda"] = b; await settle()
        m["scl"] = 1; await settle()
        m["scl"] = 0; await settle(4)

    async def bit_in():
        m["scl"] = 0; m["sda"] = 1; await settle()
        m["scl"] = 1; await settle(HALF // 2)
        v = wire_bit(dut, 3, 1)
        await settle(HALF - HALF // 2)
        m["scl"] = 0; await settle(4)
        return v

    async def byte_out(b):
        for i in range(7, -1, -1):
            await bit_out((b >> i) & 1)
        return await bit_in() == 0

    async def byte_in(ack):
        v = 0
        for _ in range(8):
            v = (v << 1) | await bit_in()
        await bit_out(0 if ack else 1)
        return v

    async def bus_start():
        m["sda"] = 1; m["scl"] = 1; await settle()
        m["sda"] = 0; await settle()
        m["scl"] = 0; await settle()

    async def bus_stop():
        m["sda"] = 0; m["scl"] = 0; await settle()
        m["scl"] = 1; await settle()
        m["sda"] = 1; await settle()

    for b in image(SLAVE_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 800)
    assert int(dut.boot_sel_o.value) == 1, "slave program must commit"

    await bus_start()
    assert await byte_out((0x42 << 1) | 0), "the die must answer its name"
    assert await byte_out(0x55), "the byte must be ACKed"
    await bus_start()                           # repeated
    assert await byte_out((0x42 << 1) | 1), "read-address ACK"
    got = await byte_in(ack=False)
    await bus_stop()
    assert got == 0x3C, f"preload must come back: {got:#x}"

    assert await z_signature(dut), \
        "the program's own queue never showed the master's byte"
