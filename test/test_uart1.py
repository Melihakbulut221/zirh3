# =============================================================================
# ZIRH-3 - second UART block suite (Cycle 33)
#
# The payload's serial port at its own boundary: a launched frame
# carries start, eight LSB-first data bits and a stop at the
# programmed rate; an injected frame lands in RXD with the valid
# flag; reading RXD clears the flag; a false start (a glitch shorter
# than half a bit) is refused; TMR silent throughout.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CTRL, DIV, TXD, RXD, STAT = 0x00, 0x04, 0x08, 0x0C, 0x10
BAUD = 8


async def bring_up(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.we_i.value = 0
    dut.rx_i.value = 1
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
    await ClockCycles(dut.clk, 2)     # rd_fire side effects need two
    v = int(dut.rdt_o.value)
    dut.cyc_i.value = 0
    await ClockCycles(dut.clk, 1)
    return v


async def send_frame(dut, byte, div=BAUD):
    bits = [0] + [(byte >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        dut.rx_i.value = b
        await ClockCycles(dut.clk, div)
    dut.rx_i.value = 1
    await ClockCycles(dut.clk, 2 * div)


async def capture_frame(dut, div=BAUD, timeout=2000):
    for _ in range(timeout):
        await ClockCycles(dut.clk, 1)
        if int(dut.tx_o.value) == 0:
            break
    else:
        raise AssertionError("start bit never came")
    await ClockCycles(dut.clk, div // 2)
    bits = []
    for _ in range(9):
        await ClockCycles(dut.clk, div)
        bits.append(int(dut.tx_o.value))
    assert bits[8] == 1, "stop bit must be high"
    return sum(b << i for i, b in enumerate(bits[:8]))


@cocotb.test()
async def test_payload_serial_port(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)
    await bus_write(dut, CTRL, 1)

    # --- TX: the frame on the pin is the byte at the rate ----------------
    await bus_write(dut, TXD, 0xA5)
    assert await capture_frame(dut) == 0xA5
    for _ in range(3000):
        if (await bus_read(dut, STAT)) & 1 == 0:
            break
    await bus_write(dut, TXD, 0x3C)
    assert await capture_frame(dut) == 0x3C

    # --- RX: an injected frame lands, valid clears on read ---------------
    await send_frame(dut, 0x99)
    await ClockCycles(dut.clk, 4)
    assert (await bus_read(dut, STAT)) & 2, "rx_valid must set"
    assert await bus_read(dut, RXD) == 0x99
    await ClockCycles(dut.clk, 2)
    assert (await bus_read(dut, STAT)) & 2 == 0, "reading RXD must clear valid"

    # --- a glitch is not a start bit -------------------------------------
    dut.rx_i.value = 0
    await ClockCycles(dut.clk, 2)     # far shorter than half a bit
    dut.rx_i.value = 1
    await ClockCycles(dut.clk, 4 * BAUD)
    assert (await bus_read(dut, STAT)) & 2 == 0, "a glitch must not frame"

    # --- second byte overwrites, software rate discipline ----------------
    await send_frame(dut, 0x11)
    await send_frame(dut, 0x22)
    await ClockCycles(dut.clk, 4)
    assert await bus_read(dut, RXD) == 0x22, "late reader gets the newest byte"

    assert int(dut.err_o.value) == 0, "TMR error under plain traffic"
    print("UART1: PASS")
