# =============================================================================
# ZIRH-3 - the interrupt fabric through the whole die (Cycle 34)
#
# An ISP-loaded program unmasks timer 0, arms it with a five-cycle
# period and irq_en, then POLLS the fabric's PENDING word until the
# overflow shows - only then does it flood 'Z'. The flood is
# therefore a proof the software SAW the interrupt through the bus;
# the bench then peeks the core's external-interrupt port to prove
# the same line reached the CPU boundary. One program: timer STAT
# stickiness, the source gating, the mask, the sub-decoded 0x6400
# window and the soc routing.
# =============================================================================

import cocotb
from cocotb.triggers import ClockCycles

from test_top_fuzz import z_signature
from test_top_isp import addi, beq, image, jal, lui, lw, start, sw, uart_send

IRQ_BASE = 0x6400
TIMER_BASE = 0x7000

# t0 = 0x6000 window base; t2 = timer bank; poll PENDING, then flood
IRQ_PROGRAM = [
    lui(5, 0x6),                    # t0 = 0x6000
    addi(6, 0, 1),                  # MASK = timer 0 only
    sw(6, 5, 0x400),
    lui(7, 0x7),                    # t2 = 0x7000
    addi(6, 0, 4),                  # RELOAD = 4 (period 5)
    sw(6, 7, 0x04),
    addi(6, 0, 0b1001),             # CTRL: en, mode timer, irq_en
    sw(6, 7, 0x00),
    lw(6, 5, 0x408),                # poll PENDING          <- loop
    beq(6, 0, -4),                  # nothing yet: poll again
    lui(10, 0x2),                   # uart
    addi(11, 0, 0x5A),
    sw(11, 10, 4),
    jal(0, -4),
]


@cocotb.test()
async def test_the_core_sees_the_timer_through_the_fabric(dut):
    await start(dut, strap=1)

    for b in image(IRQ_PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "irq program must commit"
    assert await z_signature(dut), \
        "the flood only starts after PENDING showed the overflow"

    # the same level line must be standing at the CPU boundary: the
    # timer's STAT is sticky and nobody cleared it, so bit 0 holds
    assert int(dut.u_soc.u_cpu.ext_irq_i.value) & 1, \
        "pending must reach the core's external-interrupt array"
    assert int(dut.u_soc.u_cpu.ext_irq_i.value) & ~1 == 0, \
        "masked sources must stay silent at the core"
