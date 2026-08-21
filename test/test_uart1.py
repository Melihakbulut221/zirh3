# =============================================================================
# ZIRH-3 - second UART block suite (Cycle 33, deepened Cycle 35)
#
# The payload's serial port at its own boundary: a launched frame
# carries start, eight LSB-first data bits and a stop at the
# programmed rate; an injected frame lands in the RX queue; a false
# start (a glitch shorter than half a bit) is refused; TMR silent
# throughout. Cycle 35 adds the depth laws: bytes QUEUE in order on
# both directions, sixteen deep; an overflowing byte is dropped and
# OE goes sticky while the oldest data survives; parity is emitted
# and checked when enabled (a lying frame sets PERR and never enters
# the queue); a broken stop sets FERR the same way; the second stop
# bit stretches the transmit frame by exactly one bit time.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, First, Timer

CTRL, DIV, TXD, RXD, STAT = 0x00, 0x04, 0x08, 0x0C, 0x10
BAUD = 8

EN, PEN, PODD, STOP2 = 1, 2, 4, 8
OE, FERR, PERR = 1 << 4, 1 << 5, 1 << 6


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
    # sample after the FIRST edge: a pop-on-read queue advances on the
    # strobe edge, and the value of the transaction is the head BEFORE
    # the pop - exactly what a one-cycle-ack CPU load sees
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.we_i.value = 0
    await ClockCycles(dut.clk, 1)
    v = int(dut.rdt_o.value)
    await ClockCycles(dut.clk, 1)     # rd_fire side effects need two
    dut.cyc_i.value = 0
    await ClockCycles(dut.clk, 1)
    return v


async def send_frame(dut, byte, div=BAUD, parity=None, stop=1, gap=2):
    bits = [0] + [(byte >> i) & 1 for i in range(8)]
    if parity is not None:
        bits.append(parity)
    bits.append(stop)
    for b in bits:
        dut.rx_i.value = b
        await ClockCycles(dut.clk, div)
    dut.rx_i.value = 1
    await ClockCycles(dut.clk, gap * div)


async def capture_frame(dut, div=BAUD, timeout=2000, pen=False):
    for _ in range(timeout):
        await ClockCycles(dut.clk, 1)
        if int(dut.tx_o.value) == 0:
            break
    else:
        raise AssertionError("start bit never came")
    await ClockCycles(dut.clk, div // 2)
    n = 10 if pen else 9
    bits = []
    for _ in range(n):
        await ClockCycles(dut.clk, div)
        bits.append(int(dut.tx_o.value))
    assert bits[-1] == 1, "stop bit must be high"
    byte = sum(b << i for i, b in enumerate(bits[:8]))
    return (byte, bits[8]) if pen else byte


@cocotb.test()
async def test_payload_serial_port(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)
    await bus_write(dut, CTRL, EN)

    # --- TX: the frame on the pin is the byte at the rate ----------------
    await bus_write(dut, TXD, 0xA5)
    assert await capture_frame(dut) == 0xA5
    for _ in range(3000):
        if (await bus_read(dut, STAT)) & 1 == 0:
            break
    await bus_write(dut, TXD, 0x3C)
    assert await capture_frame(dut) == 0x3C

    # --- RX: an injected frame lands, valid clears on the last pop -------
    await send_frame(dut, 0x99)
    await ClockCycles(dut.clk, 4)
    assert (await bus_read(dut, STAT)) & 2, "rx_valid must set"
    assert await bus_read(dut, RXD) == 0x99
    await ClockCycles(dut.clk, 2)
    assert (await bus_read(dut, STAT)) & 2 == 0, "an emptied queue is not valid"

    # --- a glitch is not a start bit -------------------------------------
    dut.rx_i.value = 0
    await ClockCycles(dut.clk, 2)     # far shorter than half a bit
    dut.rx_i.value = 1
    await ClockCycles(dut.clk, 4 * BAUD)
    assert (await bus_read(dut, STAT)) & 2 == 0, "a glitch must not frame"

    # --- bytes queue IN ORDER: the old overwrite law is repealed ---------
    await send_frame(dut, 0x11)
    await send_frame(dut, 0x22)
    await ClockCycles(dut.clk, 4)
    assert (await bus_read(dut, STAT) >> 8) & 0x1F == 2, "two bytes deep"
    assert await bus_read(dut, RXD) == 0x11, "the OLDEST byte pops first"
    assert await bus_read(dut, RXD) == 0x22, "then the next"

    assert int(dut.err_o.value) == 0, "TMR error under plain traffic"
    print("UART1: PASS")


async def capture_synced(dut, div=BAUD, timeout=4000):
    # from a KNOWN idle line, sync on the real falling edge - a level
    # catch on an already-running frame mistakes a zero data bit for
    # the start and reads a shifted byte
    prev = int(dut.tx_o.value)
    for _ in range(timeout):
        await ClockCycles(dut.clk, 1)
        cur = int(dut.tx_o.value)
        if prev == 1 and cur == 0:
            break
        prev = cur
    else:
        raise AssertionError("start edge never came")
    await ClockCycles(dut.clk, div // 2)
    bits = []
    for _ in range(9):
        await ClockCycles(dut.clk, div)
        bits.append(int(dut.tx_o.value))
    assert bits[8] == 1, "stop bit must be high"
    return sum(b << i for i, b in enumerate(bits[:8]))


@cocotb.test()
async def test_tx_queue_drains_in_order(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)
    await bus_write(dut, CTRL, EN)

    # the collector attaches BEFORE the first write, so every start
    # edge - including the first frame's - is caught exactly
    frames = []

    async def collect():
        for _ in range(3):
            frames.append(await capture_synced(dut))

    task = cocotb.start_soon(collect())

    # three writes back to back, no waiting: the engine owns the pacing
    for b in (0xDE, 0xAD, 0x42):
        await bus_write(dut, TXD, b)
    assert (await bus_read(dut, STAT)) & 1, "engine must be launching"
    await task
    assert frames == [0xDE, 0xAD, 0x42], "queued frames keep their order"

    assert int(dut.err_o.value) == 0
    print("UART1 TX queue: PASS")


@cocotb.test()
async def test_tx_wall_refuses_the_eighteenth(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)
    await bus_write(dut, CTRL, EN)

    frames = []

    async def collect():
        for _ in range(17):
            frames.append(await capture_synced(dut))

    task = cocotb.start_soon(collect())

    # eighteen rapid writes: the first launches at once, sixteen queue,
    # the eighteenth meets a full queue and is REFUSED
    for i in range(18):
        await bus_write(dut, TXD, 0xC0 + i)
    stat = await bus_read(dut, STAT)
    assert stat & (1 << 2), "tx_full must show while the queue is at the wall"
    assert (stat >> 16) & 0x1F == 16, "the gauge reads sixteen"
    assert int(dut.irq_tx_o.value) == 0, "no room: the tx line rests"

    await task
    assert frames == [0xC0 + i for i in range(17)], \
        "seventeen frames fly in order; the refused eighteenth never does"
    for _ in range(3000):
        if (await bus_read(dut, STAT)) & 1 == 0:
            break
    assert (await bus_read(dut, STAT) >> 16) & 0x1F == 0, "drained"
    assert int(dut.irq_tx_o.value) == 1, "room again: the tx line stands"

    assert int(dut.err_o.value) == 0
    print("UART1 TX wall: PASS")


@cocotb.test()
async def test_rx_overflow_keeps_the_oldest(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)
    await bus_write(dut, CTRL, EN)

    for i in range(16):                      # exactly what the queue holds
        await send_frame(dut, 0x40 + i, gap=1)
    await ClockCycles(dut.clk, 4)

    stat = await bus_read(dut, STAT)
    assert (stat >> 8) & 0x1F == 16, "the queue holds exactly sixteen"
    assert stat & (1 << 3), "rx_full must show"
    assert stat & OE == 0, "FULL is not a fault - only a LOSS is"
    assert int(dut.irq_rx_o.value) == 1, "bytes wait: the rx line stands"

    await send_frame(dut, 0x40 + 16, gap=1)  # the one that does not fit
    await ClockCycles(dut.clk, 4)
    stat = await bus_read(dut, STAT)
    assert stat & OE, "the seventeenth byte must flag overrun"
    assert not (stat & (FERR | PERR)), "overrun is the only complaint"

    for i in range(16):
        assert await bus_read(dut, RXD) == 0x40 + i, \
            "the oldest sixteen survive; the overflow byte is the one lost"
    assert (await bus_read(dut, STAT)) & 2 == 0, "drained"

    await bus_write(dut, STAT, OE)
    assert (await bus_read(dut, STAT)) & OE == 0, "OE is write-1-to-clear"

    assert int(dut.err_o.value) == 0
    print("UART1 overflow: PASS")


@cocotb.test()
async def test_parity_emitted_and_enforced(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)
    await bus_write(dut, CTRL, EN | PEN)

    # TX: the ninth bit makes the ones count even
    await bus_write(dut, TXD, 0xA5)          # four ones: parity 0
    byte, par = await capture_frame(dut, pen=True)
    assert byte == 0xA5 and par == 0, "even parity of 0xA5 is 0"
    for _ in range(3000):
        if (await bus_read(dut, STAT)) & 1 == 0:
            break
    await bus_write(dut, TXD, 0xA4)          # three ones: parity 1
    byte, par = await capture_frame(dut, pen=True)
    assert byte == 0xA4 and par == 1, "even parity of 0xA4 is 1"

    # RX: an honest frame lands, a lying one sets PERR and vanishes
    await send_frame(dut, 0xA5, parity=0)
    await ClockCycles(dut.clk, 4)
    assert await bus_read(dut, RXD) == 0xA5, "good parity lands"
    await send_frame(dut, 0xA5, parity=1)
    await ClockCycles(dut.clk, 4)
    stat = await bus_read(dut, STAT)
    assert stat & PERR, "bad parity must flag"
    assert stat & 2 == 0, "a lying byte never enters the queue"
    await bus_write(dut, STAT, PERR)
    assert (await bus_read(dut, STAT)) & PERR == 0, "PERR is write-1-to-clear"

    # odd parity flips the emitted bit - and the RECEIVE check flips
    # with it, which only a frame injected under PODD can prove
    await bus_write(dut, CTRL, EN | PEN | PODD)
    await ClockCycles(dut.clk, 4)
    await bus_write(dut, TXD, 0xA5)
    byte, par = await capture_frame(dut, pen=True)
    assert byte == 0xA5 and par == 1, "odd parity of 0xA5 is 1"

    await send_frame(dut, 0xA5, parity=1)    # honest under ODD rules
    await ClockCycles(dut.clk, 4)
    assert await bus_read(dut, RXD) == 0xA5, "honest odd parity lands"
    await send_frame(dut, 0xA5, parity=0)    # even parity is the lie now
    await ClockCycles(dut.clk, 4)
    stat = await bus_read(dut, STAT)
    assert stat & PERR, "an even-parity frame lies on an odd link"
    assert stat & 2 == 0, "and never enters the queue"
    await bus_write(dut, STAT, PERR)

    assert int(dut.err_o.value) == 0
    print("UART1 parity: PASS")


@cocotb.test()
async def test_broken_stop_flags_ferr(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)
    await bus_write(dut, CTRL, EN)

    await send_frame(dut, 0x77, stop=0)      # break where stop belongs
    await ClockCycles(dut.clk, 4 * BAUD)
    stat = await bus_read(dut, STAT)
    assert stat & FERR, "a broken stop must flag"
    assert stat & 2 == 0, "a broken frame never enters the queue"
    await bus_write(dut, STAT, FERR)
    assert (await bus_read(dut, STAT)) & FERR == 0, "FERR is write-1-to-clear"

    # the line recovers: the next honest frame lands
    await send_frame(dut, 0x66)
    await ClockCycles(dut.clk, 4)
    assert await bus_read(dut, RXD) == 0x66

    assert int(dut.err_o.value) == 0
    print("UART1 framing: PASS")


@cocotb.test()
async def test_second_stop_stretches_the_frame(dut):
    await bring_up(dut)
    await bus_write(dut, DIV, BAUD)

    # measure start-to-start with frames queued back to back: the
    # distance IS the frame length, and stop2 adds exactly one bit
    async def start_gap(ctrl):
        await bus_write(dut, CTRL, ctrl)
        await ClockCycles(dut.clk, 4)
        await bus_write(dut, TXD, 0x00)
        await bus_write(dut, TXD, 0x00)
        while int(dut.tx_o.value) == 1:
            await ClockCycles(dut.clk, 1)
        t0 = cocotb.utils.get_sim_time("ns")
        await ClockCycles(dut.clk, 9 * BAUD)  # clear of the data bits
        while int(dut.tx_o.value) == 0:
            await ClockCycles(dut.clk, 1)
        while int(dut.tx_o.value) == 1:
            await ClockCycles(dut.clk, 1)
        gap = cocotb.utils.get_sim_time("ns") - t0
        await ClockCycles(dut.clk, 14 * BAUD)  # let the second frame end
        return gap

    plain = await start_gap(EN)
    long = await start_gap(EN | STOP2)
    assert long - plain == BAUD * 40, \
        f"stop2 must add one bit time: {plain} -> {long}"

    assert int(dut.err_o.value) == 0
    print("UART1 stop2: PASS")
