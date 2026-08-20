# =============================================================================
# ZIRH-3 - GPIO block suite (Cycle 27)
#
# The 56-pin block at its own boundary: registers load once per bus
# write, direction gates the drive enables, inputs cross two flops
# before software sees them, the B port masks to 24 bits, and the TMR
# error stays silent through all of it.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

A_OUT, A_DIR, A_IN = 0x00, 0x04, 0x08
B_OUT, B_DIR, B_IN = 0x0C, 0x10, 0x14


async def bring_up(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.we_i.value = 0
    dut.gpio_a_i.value = 0
    dut.gpio_b_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def bus_write(dut, adr, dat):
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.dat_i.value = dat
    dut.we_i.value = 1
    await ClockCycles(dut.clk, 2)     # bus writes last two cycles
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
async def test_ports_drive_and_listen(dut):
    await bring_up(dut)

    # PORTA: out and dir land on the pins, and read back
    await bus_write(dut, A_OUT, 0xA5A5A5A5)
    await bus_write(dut, A_DIR, 0x0000FFFF)
    assert int(dut.gpio_a_o.value) == 0xA5A5A5A5
    assert int(dut.gpio_a_oe.value) == 0x0000FFFF
    assert await bus_read(dut, A_OUT) == 0xA5A5A5A5
    assert await bus_read(dut, A_DIR) == 0x0000FFFF

    # PORTB: 24 bits, upper byte masks to zero everywhere
    await bus_write(dut, B_OUT, 0xFFBEBAFE)
    await bus_write(dut, B_DIR, 0xFF123456)
    assert int(dut.gpio_b_o.value) == 0xBEBAFE
    assert int(dut.gpio_b_oe.value) == 0x123456
    assert await bus_read(dut, B_OUT) == 0x00BEBAFE
    assert await bus_read(dut, B_DIR) == 0x00123456

    # inputs cross two flops before software sees them
    dut.gpio_a_i.value = 0xDEAD1234
    dut.gpio_b_i.value = 0x0F0F0F
    await ClockCycles(dut.clk, 3)
    assert await bus_read(dut, A_IN) == 0xDEAD1234
    assert await bus_read(dut, B_IN) == 0x000F0F0F

    # a two-cycle bus write must load exactly once (wr_seen guard):
    # the register holds the FIRST cycle's data even if dat changes
    dut.cyc_i.value = 1
    dut.adr_i.value = A_OUT
    dut.dat_i.value = 0x11111111
    dut.we_i.value = 1
    await ClockCycles(dut.clk, 1)
    dut.dat_i.value = 0x22222222
    await ClockCycles(dut.clk, 1)
    dut.cyc_i.value = 0
    dut.we_i.value = 0
    await ClockCycles(dut.clk, 1)
    assert await bus_read(dut, A_OUT) == 0x11111111, \
        "the second cycle of one bus write must not reload the register"

    assert int(dut.err_o.value) == 0, "TMR error under plain register traffic"
    print("GPIO_BLOCK: PASS")
