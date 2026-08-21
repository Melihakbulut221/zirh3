# =============================================================================
# ZIRH-3 - I2C master block suite (Cycle 31)
#
# The master against a bench-modelled slave on a modelled open-drain
# bus: the wire is the AND of everyone's pull, nobody ever drives
# high. The slave ACKs, records what it was told, serves a byte on
# read legs, and - in the scenario that matters most for flight
# sensors - STRETCHES the clock and expects the master to obey.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CTRL, DIV, CMD, TXD, RXD, STAT = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14
STA, STO, WR, RD, NACK = 1, 2, 4, 8, 16


class Slave:
    """Always-ACK I2C slave with a stretch knob."""

    def __init__(self):
        self.scl_pull = 0
        self.sda_pull = 0
        self.prev_scl = 1
        self.prev_sda = 1
        self.bits = []
        self.bytes_seen = []
        self.events = []
        self.state = "idle"
        self.nbit = 0
        self.serve = 0x00
        self.stretch = 0
        self._stretch_left = 0

    def step(self, scl, sda):
        # stretch is TIME, not edges: while holding SCL there are no
        # edges to count by
        if self._stretch_left:
            self._stretch_left -= 1
            if self._stretch_left == 0:
                self.scl_pull = 0
        scl_rise = scl and not self.prev_scl
        scl_fall = (not scl) and self.prev_scl
        if scl and self.prev_scl:
            if self.prev_sda and not sda:
                self.events.append("START")
                self.state = "addr"
                self.nbit = 0
                self.bits = []
            elif sda and not self.prev_sda:
                self.events.append("STOP")
                self.state = "idle"
        if scl_rise and self.state in ("addr", "data"):
            self.bits.append(sda)
            self.nbit += 1
        if scl_fall:
            if self.state in ("addr", "data") and self.nbit == 8:
                b = sum(bit << (7 - i) for i, bit in enumerate(self.bits))
                self.bytes_seen.append(b)
                self.state = "ack"
                self.sda_pull = 1                     # ACK
                if self.stretch:
                    self.scl_pull = 1                 # and stretch
                    self._stretch_left = self.stretch * 8
            elif self.state == "ack":
                # release the ack - and if serving a read, bit 7 goes
                # on the wire NOW, or the master samples a blank
                if self.reading:
                    self.state = "read"
                    self.sda_pull = 0 if ((self.serve >> 7) & 1) else 1
                    self.rbit = 6
                else:
                    self.sda_pull = 0
                    self.state = "data"
                    self.nbit = 0
                    self.bits = []
            elif self.state == "read":
                if self.rbit >= 0:
                    self.sda_pull = 0 if ((self.serve >> self.rbit) & 1) else 1
                    self.rbit -= 1
                else:
                    self.sda_pull = 0                 # release: hear m-ack
                    self.state = "data"
                    self.nbit = 0
                    self.bits = []
        self.prev_scl = scl
        self.prev_sda = sda

    reading = False


async def bus_model(dut, slave):
    while True:
        await RisingEdge(dut.clk)
        scl = 0 if (int(dut.scl_pull_o.value) or slave.scl_pull) else 1
        sda = 0 if (int(dut.sda_pull_o.value) or slave.sda_pull) else 1
        dut.scl_i.value = scl
        dut.sda_i.value = sda
        slave.step(scl, sda)


async def bring_up(dut, slave):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.we_i.value = 0
    dut.scl_i.value = 1
    dut.sda_i.value = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    cocotb.start_soon(bus_model(dut, slave))


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


async def wait_done(dut, limit=20000):
    for _ in range(limit):
        if (await bus_read(dut, STAT)) & 1 == 0:
            return
    raise AssertionError("leg never finished")


@cocotb.test()
async def test_master_speaks_i2c(dut):
    slave = Slave()
    await bring_up(dut, slave)
    await bus_write(dut, CTRL, 1)
    await bus_write(dut, DIV, 4)

    # --- START + address byte, slave ACKs --------------------------------
    await bus_write(dut, TXD, 0xA6)
    await bus_write(dut, CMD, STA | WR)
    await wait_done(dut)
    assert "START" in slave.events, "slave must see a START"
    assert slave.bytes_seen == [0xA6], f"slave saw {slave.bytes_seen}"
    assert (await bus_read(dut, STAT)) & 2 == 0, "slave ACKed: rxack must be 0"

    # --- data byte + STOP -------------------------------------------------
    await bus_write(dut, TXD, 0x3C)
    await bus_write(dut, CMD, WR | STO)
    await wait_done(dut)
    assert slave.bytes_seen == [0xA6, 0x3C]
    assert "STOP" in slave.events, "slave must see the STOP"

    # --- read leg: slave serves, master NACKs and stops ------------------
    slave.serve = 0x5A
    slave.reading = True
    await bus_write(dut, TXD, 0xA7)
    await bus_write(dut, CMD, STA | WR)
    await wait_done(dut)
    await bus_write(dut, CMD, RD | NACK | STO)
    await wait_done(dut)
    assert await bus_read(dut, RXD) == 0x5A, "read byte must be the served one"

    # --- the stretch: a slow slave holds SCL, the master obeys -----------
    slave.reading = False
    slave.stretch = 6
    await bus_write(dut, TXD, 0xA6)
    await bus_write(dut, CMD, STA | WR)
    await wait_done(dut)
    assert slave.bytes_seen[-1] == 0xA6, "stretched leg must still deliver"
    await bus_write(dut, TXD, 0x77)
    await bus_write(dut, CMD, WR | STO)
    await wait_done(dut)
    assert slave.bytes_seen[-1] == 0x77, "post-stretch byte must land intact"

    assert int(dut.err_o.value) == 0, "TMR error under plain protocol traffic"
    print("I2C_MASTER: PASS")
