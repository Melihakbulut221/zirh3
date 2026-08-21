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


# ---------------------------------------------------------------- slave chair
SADR, SSTAT, SRXD, STXD = 0x18, 0x1C, 0x20, 0x24


async def sl_bring_up(dut):
    # the slave suite drives the wires itself - no bench peer loop
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
UE = 1 << 5
HALF = 20      # bench master half-bit in clk cycles - leisurely, like a bus


class Wire:
    """the open-drain pair as the bench master sees and drives it"""
    def __init__(self, dut):
        self.dut = dut
        self.scl = 1
        self.sda = 1

    def apply(self):
        # the DUT's pulls win low; the bench master's drive is ours
        self.dut.scl_i.value = self.scl & ~int(self.dut.scl_pull_o.value)
        self.dut.sda_i.value = self.sda & ~int(self.dut.sda_pull_o.value)


async def settle(dut, w, n=HALF):
    for _ in range(n):
        w.apply()
        await ClockCycles(dut.clk, 1)


async def m_start(dut, w):
    w.sda = 1; w.scl = 1; await settle(dut, w)
    w.sda = 0; await settle(dut, w)
    w.scl = 0; await settle(dut, w)


async def m_stop(dut, w):
    w.sda = 0; w.scl = 0; await settle(dut, w)
    w.scl = 1; await settle(dut, w)
    w.sda = 1; await settle(dut, w)


async def m_bit_out(dut, w, b):
    w.scl = 0; w.sda = b; await settle(dut, w)
    w.scl = 1; await settle(dut, w)
    w.scl = 0; await settle(dut, w, n=2)


async def m_rstart(dut, w):
    # a TRUE repeated start: raise SDA while SCL is LOW (no phantom
    # stop), then raise SCL, then drop SDA under a high clock
    w.scl = 0; w.sda = 1; await settle(dut, w)
    w.scl = 1; await settle(dut, w)
    w.sda = 0; await settle(dut, w)
    w.scl = 0; await settle(dut, w)


async def stop_watcher(dut, w, log):
    # records every STOP the DUT could see: SDA rising while SCL high
    prev = self_sda(dut, w)
    while True:
        await ClockCycles(dut.clk, 1)
        cur = self_sda(dut, w)
        if int(dut.scl_i.value) and cur == 1 and prev == 0:
            log.append(1)
        prev = cur


async def m_bit_in(dut, w):
    w.scl = 0; w.sda = 1; await settle(dut, w)         # release
    w.scl = 1; await settle(dut, w, n=HALF // 2)
    w.apply()
    v = int(self_sda(dut, w))
    await settle(dut, w, n=HALF - HALF // 2)
    w.scl = 0; await settle(dut, w)      # a FULL low half: releases
    return v                             # settle while SCL is down


def self_sda(dut, w):
    return w.sda & ~int(dut.sda_pull_o.value)


async def m_byte_out(dut, w, byte):
    for i in range(7, -1, -1):
        await m_bit_out(dut, w, (byte >> i) & 1)
    return await m_bit_in(dut, w) == 0      # True = ACKed


async def m_byte_in(dut, w, ack):
    v = 0
    for _ in range(8):
        v = (v << 1) | await m_bit_in(dut, w)
    await m_bit_out(dut, w, 0 if ack else 1)
    return v


@cocotb.test()
async def test_slave_answers_its_name(dut):
    await sl_bring_up(dut)
    w = Wire(dut)
    await bus_write(dut, SADR, 0x80 | 0x42)      # en + address 0x42

    assert await bus_read(dut, SADR) == 0xC2, "SADR readback"

    # the WRONG address one bit away is met with silence, both ways
    for probe in ((0x43 << 1) | 0, (0x43 << 1) | 1, (0x17 << 1) | 0):
        await m_start(dut, w)
        assert not await m_byte_out(dut, w, probe), \
            f"a stranger's address {probe:#x} must not be ACKed"
        await m_stop(dut, w)

    # an abandoned byte does not wedge the chair: four bits, a stop
    # from a bit boundary, then a fresh transaction lands clean
    await m_start(dut, w)
    for b in (1, 0, 1, 1):
        await m_bit_out(dut, w, b)
    await m_stop(dut, w)

    # three bytes to OUR address queue in order
    await m_start(dut, w)
    assert await m_byte_out(dut, w, (0x42 << 1) | 0), "address ACK"
    for b in (0xDE, 0xAD, 0x42):
        assert await m_byte_out(dut, w, b), "data ACK"
    await m_stop(dut, w)
    await ClockCycles(dut.clk, 4)
    stat = await bus_read(dut, SSTAT)
    assert (stat >> 8) & 0x1F == 3, "three bytes deep"
    assert stat & 1 == 0, "STOP ends busy"
    for b in (0xDE, 0xAD, 0x42):
        assert await bus_read(dut, SRXD) == b, "arrival order preserved"

    assert int(dut.err_o.value) == 0
    print("I2C slave write: PASS")


@cocotb.test()
async def test_slave_serves_its_queue(dut):
    await sl_bring_up(dut)
    w = Wire(dut)

    # with the chair EMPTY of its enable, the wire is ignored: a
    # perfectly addressed write gets silence and queues nothing
    await bus_write(dut, SADR, 0x42)             # address set, en CLEAR
    await m_start(dut, w)
    assert not await m_byte_out(dut, w, (0x42 << 1) | 0), \
        "a disabled chair must not answer even its own name"
    await m_stop(dut, w)
    assert (await bus_read(dut, SSTAT) >> 8) & 0x1F == 0, "nothing queued"

    await bus_write(dut, SADR, 0x80 | 0x42)
    for b in (0xA5, 0x3C):
        await bus_write(dut, STXD, b)
    stat = await bus_read(dut, SSTAT)
    assert (stat >> 16) & 0x1F == 2, "the tx gauge counts the preload"

    await m_start(dut, w)
    assert await m_byte_out(dut, w, (0x42 << 1) | 1), "read-address ACK"
    assert await m_byte_in(dut, w, ack=True) == 0xA5, "first serve"
    assert await m_byte_in(dut, w, ack=False) == 0x3C, "second, then NACK"
    await m_stop(dut, w)

    # starving read: all-ones served, UE sticky, W1C clears
    await m_start(dut, w)
    assert await m_byte_out(dut, w, (0x42 << 1) | 1)
    assert await m_byte_in(dut, w, ack=False) == 0xFF, "starving is all-ones"
    await m_stop(dut, w)
    await ClockCycles(dut.clk, 4)
    stat = await bus_read(dut, SSTAT)
    assert stat & UE, "underflow must flag"
    await bus_write(dut, SSTAT, UE)
    assert (await bus_read(dut, SSTAT)) & UE == 0, "UE is write-1-to-clear"

    assert int(dut.err_o.value) == 0
    print("I2C slave read: PASS")


@cocotb.test()
async def test_slave_nacks_a_full_queue(dut):
    await sl_bring_up(dut)
    w = Wire(dut)
    await bus_write(dut, SADR, 0x80 | 0x42)

    await m_start(dut, w)
    assert await m_byte_out(dut, w, (0x42 << 1) | 0)
    for i in range(16):
        assert await m_byte_out(dut, w, 0x60 + i), f"byte {i} fits"
    # the seventeenth meets the wall: NACK, nothing lost
    assert not await m_byte_out(dut, w, 0x99), \
        "a full queue must NACK - backpressure, not loss"
    await m_stop(dut, w)
    await ClockCycles(dut.clk, 4)
    stat = await bus_read(dut, SSTAT)
    assert (stat >> 8) & 0x1F == 16, "sixteen held"
    for i in range(16):
        assert await bus_read(dut, SRXD) == 0x60 + i, "the elders live"

    assert int(dut.err_o.value) == 0
    print("I2C slave wall: PASS")


@cocotb.test()
async def test_repeated_start_switches_direction(dut):
    await sl_bring_up(dut)
    w = Wire(dut)
    await bus_write(dut, SADR, 0x80 | 0x42)
    await bus_write(dut, STXD, 0x77)

    # write one byte, REPEATED start, read one back - no stop between,
    # and a wire watcher PROVES no phantom stop reached the detectors
    stops = []
    watcher = cocotb.start_soon(stop_watcher(dut, w, stops))
    await m_start(dut, w)
    assert await m_byte_out(dut, w, (0x42 << 1) | 0)
    stat = await bus_read(dut, SSTAT)
    assert stat & 1, "busy must STAND mid-transaction"
    assert await m_byte_out(dut, w, 0x55)
    await m_rstart(dut, w)                       # a TRUE repeated start
    assert stops == [], "the bench leaked a stop before the Sr"
    assert await m_byte_out(dut, w, (0x42 << 1) | 1)
    assert await m_byte_in(dut, w, ack=False) == 0x77
    watcher.kill()
    await m_stop(dut, w)
    await ClockCycles(dut.clk, 4)
    assert await bus_read(dut, SRXD) == 0x55

    # the master chair is parked while the slave sits - with the
    # master ENABLED, so the refusal is the ~sl_en gate's own doing
    await bus_write(dut, CTRL, 1)
    await bus_write(dut, DIV, 8)
    await bus_write(dut, CMD, 0x5)               # STA|WR: a real leg
    await ClockCycles(dut.clk, 16)
    assert (await bus_read(dut, STAT)) & 1 == 0, \
        "a parked master must refuse the leg"
    assert int(dut.scl_pull_o.value) == 0, \
        "and its engine must never touch the clock"

    assert int(dut.err_o.value) == 0
    print("I2C slave rs: PASS")
