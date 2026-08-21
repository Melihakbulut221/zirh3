# =============================================================================
# ZIRH-3 - SPI master block suite (Cycle 32, deepened Cycle 36)
#
# The master against a bench slave that does what real mode-0 and
# mode-3 devices do: sample MOSI on the rising edge, advance MISO on
# the falling edge, hold bit 7 ready before the first edge ever
# comes. Full duplex both ways, both modes, CS under software's
# thumb, TMR silent throughout. Cycle 36 adds the depth and width
# laws: words of 4 to 16 bits on the same wire discipline, sixteen
# deep queues on both directions (a burst of queued words flies
# under one held CS), the overflow that drops the newcomer and
# flags OE, and the decoded chip selects CSSEL steers - still
# software-owned, only reaching pins under MCS.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CTRL, DIV, TXD, RXD, STAT, WLEN = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14
EN, CPOL, CPHA, CS = 1, 2, 4, 8
OE = 1 << 4


class Slave:
    def __init__(self, nbits=8):
        self.nbits = nbits
        self.cpha = 0
        self.serve = 0x00
        self.prev_sck = 0
        self.bits = []
        self.bytes_seen = []
        self.rbit = nbits - 1
        self.miso = 0

    def reset_frame(self):
        self.bits = []
        self.rbit = self.nbits - 1
        self.miso = (self.serve >> (self.nbits - 1)) & 1

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
            if len(self.bits) == self.nbits:
                self.bytes_seen.append(
                    sum(b << (self.nbits - 1 - i)
                        for i, b in enumerate(self.bits)))
                self.bits = []
        if (not sck) and self.prev_sck:          # falling: advance
            if self.cpha:
                # mode 3: data is PRESENTED on the leading (falling)
                # edge - the MSB rides the first fall, not the select
                self.miso = (self.serve >> self.rbit) & 1
                self.rbit = self.rbit - 1 if self.rbit > 0 else self.nbits - 1
            else:
                self.rbit = self.rbit - 1 if self.rbit > 0 else self.nbits - 1
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
                       int(dut.cs_n_o.value) & 1)
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
        stat = await bus_read(dut, STAT)
        if stat & 1 == 0 and (stat >> 16) & 0x1F == 0:
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
    assert int(dut.cs_n_o.value) & 1 == 0, "software CS must reach the pin"
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
    assert int(dut.cs_n_o.value) & 1 == 1

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


@cocotb.test()
async def test_words_of_every_width(dut):
    # asymmetric values so a reversed bit order cannot sneak past,
    # BOTH phases at every width - the final trailing edge of a
    # CPHA-1 word is itself a sampling edge
    for cpha in (0, 1):
        for wlen, tx, serve in ((4, 0xB, 0x6), (12, 0xA53, 0x9C4),
                                (16, 0xDEAD, 0xB0F1)):
            slave = Slave(nbits=wlen)
            slave.cpha = cpha
            await bring_up(dut, slave)
            slave.serve = serve
            slave.reset_frame()
            await bus_write(dut, DIV, 4)
            assert await bus_read(dut, WLEN) == 8, \
                "WLEN must reset to the Cycle 32 byte"
            await bus_write(dut, WLEN, wlen)
            assert await bus_read(dut, WLEN) == wlen, "WLEN readback"
            mode = (EN | CPOL | CPHA) if cpha else EN
            await bus_write(dut, CTRL, mode)
            await ClockCycles(dut.clk, 4)
            await bus_write(dut, CTRL, mode | CS)
            await bus_write(dut, TXD, tx)
            await wait_done(dut)
            assert slave.bytes_seen == [tx], \
                f"cpha {cpha} wlen {wlen}: slave saw {slave.bytes_seen}"
            got = await bus_read(dut, RXD)
            assert got == serve, \
                f"cpha {cpha} wlen {wlen}: RXD {got:#x}, wanted {serve:#x}"
            assert int(dut.err_o.value) == 0
    print("SPI widths: PASS")


@cocotb.test()
async def test_burst_flies_under_one_select(dut):
    slave = Slave()
    await bring_up(dut, slave)
    slave.serve = 0x11
    slave.reset_frame()
    # DIV 4: reads need a half-bit longer than the two-flop listener's
    # lag (the DIV >= 3 law in the block header) - a DIV-2 read hands
    # back every reply one bit stale
    await bus_write(dut, DIV, 4)
    await bus_write(dut, CTRL, EN | CS)

    # three words queued back to back: the engine drains them itself
    for b in (0x21, 0x42, 0x84):
        await bus_write(dut, TXD, b)
    await wait_done(dut)
    assert slave.bytes_seen == [0x21, 0x42, 0x84], \
        f"burst order broke: {slave.bytes_seen}"
    assert (await bus_read(dut, STAT) >> 8) & 0x1F == 3, "three words wait"
    for _ in range(3):
        await bus_read(dut, RXD)

    # seventeen unread transfers with DISTINCT replies: sixteen fill
    # the queue with no complaint, the seventeenth is the one lost -
    # and the survivors prove it was the NEWCOMER that died
    for i in range(16):
        slave.serve = 0x20 + i
        slave.reset_frame()
        await bus_write(dut, TXD, i)
        await wait_done(dut)
    stat = await bus_read(dut, STAT)
    assert (stat >> 8) & 0x1F == 16, "exactly full"
    assert stat & OE == 0, "FULL is not a fault - only a LOSS is"
    assert int(dut.rdy_o.value) == 1, \
        "tx queue empty: the room line stands (the repurposed law)"
    slave.serve = 0x99
    slave.reset_frame()
    await bus_write(dut, TXD, 0x77)
    await wait_done(dut)
    stat = await bus_read(dut, STAT)
    assert (stat >> 8) & 0x1F == 16, "still sixteen"
    assert stat & OE, "the lost reply must flag"
    for i in range(16):
        got = await bus_read(dut, RXD)
        assert got == 0x20 + i, \
            f"survivor {i}: {got:#x} - the OLDEST must live, got wrong order"
    await bus_write(dut, STAT, OE)
    assert (await bus_read(dut, STAT)) & OE == 0, "OE is write-1-to-clear"

    assert int(dut.err_o.value) == 0
    print("SPI burst: PASS")


@cocotb.test()
async def test_decoded_selects_under_mcs(dut):
    slave = Slave()
    await bring_up(dut, slave)
    MCS = 1 << 6

    await bus_write(dut, CTRL, EN)
    assert int(dut.cs_n_o.value) == 0xF, "nothing selected, all lines high"
    assert int(dut.mcs_lease_o.value) == 0, "no MCS, no extra pins"

    # the classic line answers CSSEL 0 exactly as it always did
    await bus_write(dut, CTRL, EN | CS)
    assert int(dut.cs_n_o.value) == 0b1110

    # CSSEL steers the SAME software-owned assert to another line
    for sel in (1, 2, 3):
        await bus_write(dut, CTRL, EN | CS | MCS | (sel << 4))
        assert int(dut.cs_n_o.value) == 0xF & ~(1 << sel), \
            f"cssel {sel} must lower exactly line {sel}"
        assert int(dut.mcs_lease_o.value) == 1, "MCS leases the extra pins"

    await bus_write(dut, CTRL, EN | MCS)
    assert int(dut.cs_n_o.value) == 0xF, "release opens every line"

    assert int(dut.err_o.value) == 0
    print("SPI selects: PASS")


@cocotb.test()
async def test_wlen_travels_with_the_word(dut):
    slave = Slave(nbits=16)
    await bring_up(dut, slave)
    slave.serve = 0xFFFF
    slave.reset_frame()
    await bus_write(dut, DIV, 4)
    await bus_write(dut, WLEN, 16)
    await bus_write(dut, CTRL, EN | CS)
    await bus_write(dut, TXD, 0x8001)
    # the 16-bit word is on the wire; reconfigure for the NEXT one
    assert (await bus_read(dut, STAT)) & 1, "still in flight"
    await bus_write(dut, WLEN, 4)
    await wait_done(dut)
    got = await bus_read(dut, RXD)
    assert got == 0xFFFF, \
        f"the in-flight reply lost bits to the new length: {got:#x}"
    assert int(dut.err_o.value) == 0
    print("SPI wlen latch: PASS")
