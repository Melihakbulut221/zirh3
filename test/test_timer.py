# =============================================================================
# ZIRH-3 - timer/PWM bank block suite (Cycle 30)
#
# The 24-timer bank at its own boundary: the down-counter wraps and
# raises its sticky flag, the flag clears on write-1, PWM carries the
# programmed duty on the pin, capture latches the free-runner on a
# synchronized edge, pulse mode counts edges and nothing else, ALTB
# owns the mux bits, and the TMR error stays silent throughout.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CTRL, RELOAD, CMP, COUNT, CAP, STAT = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14
ALTB = 0x780


def treg(i, off):
    return 0x20 * i + off


async def bring_up(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.we_i.value = 0
    dut.cap_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def bus_write(dut, adr, dat):
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.dat_i.value = dat
    dut.we_i.value = 1
    await ClockCycles(dut.clk, 2)
    dut.cyc_i.value = 0
    dut.we_i.value = 0
    await ClockCycles(dut.clk, 1)


async def bus_read(dut, adr):
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.we_i.value = 0
    await ClockCycles(dut.clk, 1)
    v = int(dut.rdt_o.value)
    dut.cyc_i.value = 0
    await ClockCycles(dut.clk, 1)
    return v


@cocotb.test()
async def test_bank_of_24(dut):
    await bring_up(dut)

    # --- timer mode on timer 3: wraps, flags, clears ---------------------
    await bus_write(dut, treg(3, RELOAD), 10)
    await bus_write(dut, treg(3, CTRL), 0b0001)          # en, mode 0
    await ClockCycles(dut.clk, 40)                       # several wraps
    assert (await bus_read(dut, treg(3, STAT))) & 1 == 1, "ovf must set"
    await bus_write(dut, treg(3, STAT), 1)               # W1C
    v = await bus_read(dut, treg(3, STAT))
    assert v & 1 == 0, "ovf must clear on write-1"

    # --- PWM on timer 7: duty visible on the pin -------------------------
    await bus_write(dut, treg(7, RELOAD), 9)             # period 10
    await bus_write(dut, treg(7, CMP), 3)                # duty 30%
    await bus_write(dut, treg(7, CTRL), 0b0011)          # en, mode 1
    highs = 0
    for _ in range(100):
        await ClockCycles(dut.clk, 1)
        highs += (int(dut.pwm_o.value) >> 7) & 1
    assert 25 <= highs <= 35, f"PWM duty {highs}/100, wanted ~30"

    # --- capture on timer 11: a synchronized edge latches the count ------
    await bus_write(dut, treg(11, CTRL), 0b0101)         # en, mode 2
    await ClockCycles(dut.clk, 20)
    dut.cap_i.value = 1 << 11
    await ClockCycles(dut.clk, 5)
    dut.cap_i.value = 0
    stat = await bus_read(dut, treg(11, STAT))
    assert stat & 2, "capture flag must set"
    cap = await bus_read(dut, treg(11, CAP))
    cnt = await bus_read(dut, treg(11, COUNT))
    assert 0 < cap <= cnt, f"capture {cap} must hold an earlier count than {cnt}"

    # --- pulse mode on timer 23: edges count, time does not --------------
    await bus_write(dut, treg(23, CTRL), 0b0111)         # en, mode 3
    for _ in range(5):
        dut.cap_i.value = 1 << 23
        await ClockCycles(dut.clk, 3)
        dut.cap_i.value = 0
        await ClockCycles(dut.clk, 3)
    await ClockCycles(dut.clk, 20)                       # idle: no counting
    assert await bus_read(dut, treg(23, COUNT)) == 5, "five edges, count five"

    # --- ALTB owns the mux bits ------------------------------------------
    await bus_write(dut, ALTB, 0x000081)
    assert int(dut.alt_o.value) == 0x000081

    # --- timers are independent: timer 0 untouched, no irq ---------------
    assert await bus_read(dut, treg(0, CTRL)) == 0
    assert int(dut.timer_irq_o.value) == 0

    # --- irq: timer 0 overflow with irq_en reaches the pin ---------------
    await bus_write(dut, treg(0, RELOAD), 4)
    await bus_write(dut, treg(0, CTRL), 0b1001)          # en, mode 0, irq_en
    await ClockCycles(dut.clk, 20)
    assert int(dut.timer_irq_o.value) == 1, "timer 0 ovf must raise irq"
    # a running 5-cycle timer re-overflows before any bus read can
    # look: stop it first, then clear, then judge
    await bus_write(dut, treg(0, CTRL), 0b1000)          # en off, irq_en kept
    await bus_write(dut, treg(0, STAT), 1)
    await ClockCycles(dut.clk, 2)
    assert int(dut.timer_irq_o.value) == 0, "irq must drop with the flag"

    assert int(dut.err_o.value) == 0, "TMR error under plain traffic"
    print("TIMER_BANK: PASS")
