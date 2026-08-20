# =============================================================================
# ZIRH-3 - GPIO through the whole die (Cycle 27)
#
# The block suite proves the registers; this proves the CHAIN: an
# ISP-loaded program - arbitrary code, written after tape-out - takes
# ownership of the 56 pins. It drives a pattern out of PORTA, opens
# every PORTA driver, reads the pattern the bench holds on PORTB's
# pins through the synchronizers, and shouts its verdict on the UART:
# a 'Z' flood iff the readback matched. The bench then checks the
# PORTA pins directly - both directions of the pin boundary, one
# program.
# =============================================================================

import cocotb
from cocotb.triggers import ClockCycles

from test_top_fuzz import z_signature
from test_top_isp import (addi, beq, image, jal, lui, lw, start, sw,
                          uart_send)

GPIO_BASE = 0x6000
B_PATTERN = 0x123123      # what the bench holds on PORTB's pins

# t0=gpio, drive 0xA5A5A5A5 out of PORTA (all pins), read PORTB_IN,
# compare against the bench's pattern, flood the verdict byte forever
GPIO_PROGRAM = [
    lui(5, GPIO_BASE >> 12),        # t0 = 0x6000
    lui(6, 0xA5A5A), addi(6, 6, 0x5A5),
    sw(6, 5, 0x00),                 # PORTA_OUT = 0xA5A5A5A5
    addi(7, 0, -1),
    sw(7, 5, 0x04),                 # PORTA_DIR = all drive
    lw(8, 5, 0x14),                 # t3 = PORTB_IN
    lui(9, 0x123 >> 0), addi(9, 9, 0x123),  # s1 = 0x00123123
    lui(10, 0x2),                   # a0 = uart base
    addi(11, 0, 0x5A),              # verdict = 'Z'
    beq(8, 9, 8),                   # matched: keep 'Z'
    addi(11, 0, 0x46),              # mismatched: 'F'
    sw(11, 10, 4),                  # UART_TXDATA = verdict
    jal(0, -4),                     # shout it forever
]


@cocotb.test()
async def test_loaded_code_owns_the_pins(dut):
    await start(dut, strap=1)
    # after start(), which parks all gpio inputs at zero; the program
    # reads PORTB long after the image load, so this is early enough
    dut.gpio_b_i.value = B_PATTERN

    for b in image(GPIO_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "gpio program must commit"
    # the program is mid-flood by the time we listen - align-free
    # signature search, not a byte hunt (Cycle 26's trap, same cure)
    assert await z_signature(dut), \
        "PORTB readback mismatched - the program shouted something else"

    assert int(dut.gpio_a_o.value) == 0xA5A5A5A5, "PORTA pins must carry the pattern"
    assert int(dut.gpio_a_oe.value) == 0xFFFFFFFF, "PORTA must drive all 32 pins"
    assert int(dut.gpio_b_oe.value) == 0, "PORTB never asked to drive"
