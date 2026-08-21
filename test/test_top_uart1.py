# =============================================================================
# ZIRH-3 - the second UART through the whole die (Cycle 33)
#
# The ledger-closing test. An ISP-loaded program brings up UART1 at
# its own programmed rate on PORTA pins 16/17, waits for the byte
# the bench sends it, and answers by transmitting that byte back on
# UART1 itself - then floods 'Z' on UART0 to say the round trip
# matched. Two serial ports, two rates, one program: the yardstick's
# last column, exercised in both directions at once.
# =============================================================================

import cocotb
from cocotb.triggers import ClockCycles

from test_top_fuzz import z_signature
from test_top_isp import (addi, andi, beq, bne, image, jal, lui, lw, start,
                          sw, uart_send)

U1 = 0x7B00
U1DIV = 16

U1_PROGRAM = [
    lui(5, 0x8), addi(5, 5, -0x500),   # t0 = 0x7B00 (sign lesson applied)
    addi(6, 0, U1DIV), sw(6, 5, 0x04), # DIV
    addi(6, 0, 1),     sw(6, 5, 0x00), # CTRL en
    # wait for rx_valid
    lw(7, 5, 0x10), andi(7, 7, 2), beq(7, 0, -8),
    lw(8, 5, 0x0C),                    # the byte the bench sent
    sw(8, 5, 0x08),                    # echo it back on UART1
    # expected 0x77?  verdict on UART0
    addi(9, 0, 0x77),
    lui(10, 0x2),
    addi(11, 0, 0x5A),
    beq(8, 9, 8),
    addi(11, 0, 0x46),
    sw(11, 10, 4),
    jal(0, -4),
]


async def u1_send(dut, byte, div=U1DIV):
    bits = [0] + [(byte >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        v = int(dut.gpio_a_i.value) & ~(1 << 17)
        dut.gpio_a_i.value = v | (b << 17)
        await ClockCycles(dut.clk, div)
    dut.gpio_a_i.value = int(dut.gpio_a_i.value) | (1 << 17)


async def u1_capture(dut, div=U1DIV, timeout=200000):
    for _ in range(timeout):
        await ClockCycles(dut.clk, 1)
        oe = int(dut.gpio_a_oe.value)
        if (oe >> 16) & 1 and ((int(dut.gpio_a_o.value) >> 16) & 1) == 0:
            break
    else:
        raise AssertionError("UART1 start bit never came")
    await ClockCycles(dut.clk, div // 2)
    bits = []
    for _ in range(9):
        await ClockCycles(dut.clk, div)
        bits.append((int(dut.gpio_a_o.value) >> 16) & 1)
    assert bits[8] == 1, "stop bit must be high"
    return sum(b << i for i, b in enumerate(bits[:8]))


@cocotb.test()
async def test_two_uarts_two_rates(dut):
    await start(dut, strap=1)
    # a serial line IDLES HIGH; start() parks gpio inputs low and a
    # low rx is a permanent false start (the PORTB-pattern lesson,
    # serial edition)
    dut.gpio_a_i.value = 1 << 17

    for b in image(U1_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)
    assert int(dut.boot_sel_o.value) == 1, "uart1 program must commit"

    # give the program time to enable the port, then feed it a byte
    await ClockCycles(dut.clk, 2000)
    await u1_send(dut, 0x77)

    echoed = await u1_capture(dut)
    assert echoed == 0x77, f"UART1 echoed {hex(echoed)}"
    assert await z_signature(dut), "round trip mismatched on the verdict port"
