# =============================================================================
# ZIRH-3 - SPI master block suite (Cycle 32)
#
# The master against a bench slave that does what real mode-0 and
# mode-3 devices do: sample MOSI on the rising edge, advance MISO on
# the falling edge, hold bit 7 ready before the first edge ever
# comes. Full duplex both ways, both modes, CS under software's
# thumb, TMR silent throughout.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CTRL, DIV, TXD, RXD, STAT = 0x00, 0x04, 0x08, 0x0C, 0x10
EN, CPOL, CPHA, CS = 1, 2, 4, 8


class Slave:
    def __init__(self):
        self.cpha = 0
        self.serve = 0x00
        self.prev_sck = 0
        self.bits = []
        self.bytes_seen = []
        self.rbit = 7
        self.miso = 0

    def reset_frame(self):
        self.bits = []
        self.rbit = 7
        self.miso = (self.serve >> 7) & 1

    def step(self, sck, mosi, cs_n=0):
        # a real slave is deaf while deselected - reconfiguration
        # edges between frames must not count as data
        if cs_n:
            self.prev_sck = sck
            self.bits = []
            self.reset_frame()
            return
        if sck and not self.prev_sck:            # rising: sample
            self.bits.append(mosi)
            if len(self.bits) == 8:
                self.bytes_seen.append(
                    sum(b << (7 - i) for i, b in enumerate(self.bits)))
                self.bits = []
        if (not sck) and self.prev_sck:          # falling: advance
            if self.cpha:
                # mode 3: data is PRESENTED on the leading (falling)
                # edge - bit 7 rides the first fall, not the select
                self.miso = (self.serve >> self.rbit) & 1
                self.rbit = self.rbit - 1 if self.rbit > 0 else 7
            else:
                self.rbit = self.rbit - 1 if self.rbit > 0 else 7
                self.miso = (self.serve >> self.rbit) & 1
        self.prev_sck = sck


async def bring_up(dut, slave):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.we_i.value = 0
    dut.miso_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    async def pins():
        while True:
            await RisingEdge(dut.clk)
            slave.step(int(dut.sck_o.value), int(dut.mosi_o.value),
                       int(dut.cs_n_o.value))
            dut.miso_i.value = slave.miso

    cocotb.start_soon(pins())


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


async def wait_done(dut, limit=5000):
    for _ in range(limit):
        if (await bus_read(dut, STAT)) & 1 == 0:
            return
    raise AssertionError("transfer never finished")


@cocotb.test()
async def test_master_speaks_spi(dut):
    slave = Slave()
    await bring_up(dut, slave)

    # --- mode 0: full duplex both directions -----------------------------
    slave.serve = 0x5A
    slave.reset_frame()
    await bus_write(dut, DIV, 4)
    await bus_write(dut, CTRL, EN | CS)
    assert int(dut.cs_n_o.value) == 0, "software CS must reach the pin"
    await bus_write(dut, TXD, 0xA6)
    await wait_done(dut)
    assert slave.bytes_seen == [0xA6], f"slave saw {slave.bytes_seen}"
    assert await bus_read(dut, RXD) == 0x5A, "served byte must land in RXD"

    # --- a second byte in the same CS frame ------------------------------
    slave.serve = 0xC3
    slave.reset_frame()
    await bus_write(dut, TXD, 0x3C)
    await wait_done(dut)
    assert slave.bytes_seen == [0xA6, 0x3C]
    assert await bus_read(dut, RXD) == 0xC3

    await bus_write(dut, CTRL, EN)           # release CS
    assert int(dut.cs_n_o.value) == 1

    # --- mode 3: same story, inverted idle -------------------------------
    slave2 = Slave()
    slave2.cpha = 1
    slave2.serve = 0x99
    slave2.reset_frame()
    # rebind the pin loop's slave by swapping state wholesale
    slave.__dict__.update(slave2.__dict__)
    # configure THEN select - flipping CPOL in the same write that
    # asserts CS hands the slave a config edge dressed as data
    await bus_write(dut, CTRL, EN | CPOL | CPHA)
    await ClockCycles(dut.clk, 4)
    assert int(dut.sck_o.value) == 1, "mode 3 idles the clock HIGH"
    await bus_write(dut, CTRL, EN | CPOL | CPHA | CS)
    await bus_write(dut, TXD, 0x81)
    await wait_done(dut)
    assert slave.bytes_seen[-1] == 0x81, f"mode 3: slave saw {slave.bytes_seen}"
    assert await bus_read(dut, RXD) == 0x99, "mode 3 read must land too"

    assert int(dut.err_o.value) == 0, "TMR error under plain traffic"
    print("SPI_MASTER: PASS")
