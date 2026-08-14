# ZIRH - the clock-loss observer: the watchman does not sleep when
# the town does. The main clock here is hand-driven so the test can
# genuinely kill it - a cocotb Clock cannot die.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, NextTimeStep, ReadOnly, RisingEdge, Timer


class MainClock:
    def __init__(self, dut, period_ns=40):
        self.dut = dut
        self.period = period_ns
        self.running = True
        cocotb.start_soon(self._drive())

    async def _drive(self):
        while True:
            if self.running:
                self.dut.clk.value = 1
                await Timer(self.period // 2, unit="ns")
                self.dut.clk.value = 0
                await Timer(self.period // 2, unit="ns")
            else:
                await Timer(self.period, unit="ns")


async def ro_read(dut, name):
    await ReadOnly()
    v = int(getattr(dut, name).value)
    await NextTimeStep()
    return v


@cocotb.test()
async def test_clkobs(dut):
    # the observer's own clock: independent, deliberately not a
    # multiple of the main period
    cocotb.start_soon(Clock(dut.ro_clk, 97, unit="ns").start())
    main = MainClock(dut)
    dut.clear_i.value = 0
    dut.rst_n.value = 0
    dut.ro_rst_n.value = 0
    await Timer(400, unit="ns")
    dut.rst_n.value = 1
    dut.ro_rst_n.value = 1
    await Timer(2000, unit="ns")

    # 1. healthy: ok high, no events
    await ReadOnly()
    assert int(dut.clk_ok_o.value) == 1
    assert int(dut.evt_loss_o.value) == 0
    assert int(dut.loss_cnt_o.value) == 0
    await NextTimeStep()

    # 2. kill the main clock: loss within LOSS_RO_CYCLES of RO time
    main.running = False
    await Timer(97 * 16, unit="ns")
    await ReadOnly()
    assert int(dut.clk_ok_o.value) == 0, "observer missed the death"
    assert int(dut.evt_loss_o.value) == 1, "sticky event not set"
    assert int(dut.loss_cnt_o.value) == 1
    await NextTimeStep()

    # 3. resurrect: ok returns after RECOVER_TOGGLES, sticky stays
    main.running = True
    await Timer(97 * 24, unit="ns")
    await ReadOnly()
    assert int(dut.clk_ok_o.value) == 1, "observer missed the recovery"
    assert int(dut.evt_loss_o.value) == 1, "sticky must survive recovery"
    await NextTimeStep()

    # 4. clear the sticky record
    await RisingEdge(dut.ro_clk)
    await NextTimeStep()
    dut.clear_i.value = 1
    await ClockCycles(dut.ro_clk, 2)
    await NextTimeStep()
    dut.clear_i.value = 0
    await ClockCycles(dut.ro_clk, 2)
    await ReadOnly()
    assert int(dut.evt_loss_o.value) == 0
    await NextTimeStep()

    # 5. a second death counts separately
    main.running = False
    await Timer(97 * 16, unit="ns")
    await ReadOnly()
    assert int(dut.clk_ok_o.value) == 0
    assert int(dut.loss_cnt_o.value) == 2, "second loss not counted"
    await NextTimeStep()
    main.running = True
    await Timer(97 * 24, unit="ns")

    dut._log.info("clkobs: death seen, recovery seen, sticky record "
                  "kept and cleared, second death counted")
