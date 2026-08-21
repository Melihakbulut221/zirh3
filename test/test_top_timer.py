# =============================================================================
# ZIRH-3 - the timer bank through the whole die (Cycle 30)
#
# An ISP-loaded program leases PORTB pin 5 to timer 5, programs a 30
# percent duty at a 10-cycle period, and floods 'Z' to say it is done
# configuring. The bench then MEASURES the duty on the pin the GPIO
# block used to own - the alternate-function mux, the TMR'd timer
# registers and the pin boundary, one program.
# =============================================================================

import cocotb
from cocotb.triggers import ClockCycles

from test_top_fuzz import z_signature
from test_top_isp import addi, image, jal, lui, start, sw, uart_send

TIMER_BASE = 0x7000

# t0 = timer bank; lease pin 5, period 10, duty 3/10, enable pwm, flood
TIMER_PROGRAM = [
    lui(5, TIMER_BASE >> 12),       # t0 = 0x7000
    addi(6, 0, 0x20),               # ALTB bit 5
    sw(6, 5, 0x780),
    addi(6, 0, 9),                  # RELOAD = 9 (period 10)
    sw(6, 5, 0x20 * 5 + 0x04),
    addi(6, 0, 3),                  # CMP = 3 (30 percent)
    sw(6, 5, 0x20 * 5 + 0x08),
    addi(6, 0, 0b0011),             # CTRL: en, mode pwm
    sw(6, 5, 0x20 * 5 + 0x00),
    lui(10, 0x2),                   # uart
    addi(11, 0, 0x5A),
    sw(11, 10, 4),
    jal(0, -4),
]


@cocotb.test()
async def test_loaded_code_runs_a_pwm(dut):
    await start(dut, strap=1)

    for b in image(TIMER_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "timer program must commit"
    assert await z_signature(dut), "the program never said it finished"

    assert int(dut.gpio_b_oe.value) & (1 << 5), \
        "the leased pin must drive"
    highs = 0
    for _ in range(200):
        await ClockCycles(dut.clk, 1)
        highs += (int(dut.gpio_b_o.value) >> 5) & 1
    assert 50 <= highs <= 70, f"duty {highs}/200, wanted ~60 (30 percent)"

    # the pins the bank did NOT lease still belong to the GPIO block
    assert int(dut.gpio_b_oe.value) & ~(1 << 5) == 0, \
        "unleased PORTB pins must stay un-driven"
