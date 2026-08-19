# =============================================================================
# ZIRH-3 - the CPU-carrying top: ISP end to end (import ladder rung 3)
# test/test_top_isp.py
#
# The ZIRH-2 contract, re-proven on this die's own composition: stream a
# CRC32-sealed image over the UART pin, watch the loader commit it, and
# observe the LOADED program running - not by peeking at state, but by
# what it says on the TX pin. Then the negative: a corrupt image never
# runs and the golden ROM comes back instead. Firmware is data, so the
# testbench writes firmware (its own three-format assembler).
# =============================================================================

import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly

CLK_NS = 40
DIV = 20                     # RESET_DIV override in Makefile.top
MAGIC = 0x5A495248

UART_BASE = 0x2000           # slot 2
UART_STATUS = UART_BASE + 0x0
UART_TXDATA = UART_BASE + 0x4


def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def sw(rs2, rs1, off):
    return (((off >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (0x2 << 12) | ((off & 0x1F) << 7) | 0x23


def lw(rd, rs1, off):
    return ((off & 0xFFF) << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03


def andi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x13


def _branch(rs1, rs2, off, f3):
    imm = off & 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def beq(rs1, rs2, off):
    return _branch(rs1, rs2, off, 0x0)


def bne(rs1, rs2, off):
    return _branch(rs1, rs2, off, 0x1)


def srli(rd, rs1, shamt):
    return ((shamt & 0x1F) << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x13


def jal(rd, off):
    imm = off & 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F


# the loaded program: shout 'Z' on the UART forever. t0 = UART base;
# the TX register swallows writes whenever ready, and a busy TX drops
# them - for this proof a visible 'Z' stream is all that matters.
PROGRAM = [
    lui(5, UART_BASE >> 12),     # t0 = 0x2000
    addi(6, 0, 0x5A),            # t1 = 'Z'
    sw(6, 5, 4),                 # UART_TXDATA = 'Z'
    jal(0, -4),                  # again, forever
]


def image(words, crc=None, magic=MAGIC):
    payload = b''.join(w.to_bytes(4, 'little') for w in words)
    c = zlib.crc32(payload) if crc is None else crc
    return (magic.to_bytes(4, 'little') + len(words).to_bytes(2, 'little')
            + (1).to_bytes(2, 'little') + c.to_bytes(4, 'little') + payload)


async def start(dut, strap):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.pwr_good_i.value = 1
    dut.boot_strap_i.value = strap
    dut.dbg_unlock_strap_i.value = 0
    dut.uart_rx_i.value = 1
    dut.tck_i.value = 0
    dut.tms_i.value = 0
    dut.tdi_i.value = 0
    dut.trst_n_i.value = 1
    dut.rst_n_pad.value = 0
    await ClockCycles(dut.clk, 8)
    dut.rst_n_pad.value = 1
    # POR settle (POR_CYCLES=16 in the makefile) + strap sampling
    await ClockCycles(dut.clk, 60)


async def uart_send(dut, value):
    await RisingEdge(dut.clk)
    bits = [0] + [(value >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        dut.uart_rx_i.value = b
        await ClockCycles(dut.clk, DIV)
    dut.uart_rx_i.value = 1
    await ClockCycles(dut.clk, 3 * DIV)


async def uart_capture(dut, timeout_cycles):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.uart_tx_o.value) == 0:
            break
    else:
        return None
    await ClockCycles(dut.clk, DIV // 2)
    bits = []
    for _ in range(9):
        await ClockCycles(dut.clk, DIV)
        await ReadOnly()
        bits.append(int(dut.uart_tx_o.value))
    if bits[8] != 1:
        return None
    return sum(b << i for i, b in enumerate(bits[:8]))


async def hunt_echo(dut, cmd, target, attempts=8):
    """The ground station's echo discipline, in miniature. The shared
    UART interleaves telemetry frames with console bytes, and the
    arbiter keeps frames ATOMIC on the wire - but a listener that tunes
    in mid-frame locks onto a payload bit as a start bit and never
    recovers alignment. So: wait for a clean idle gap (frames are ~4k
    cycles apart), SEND the command from alignment, consume any frame
    that starts (sync pair, then its 18 bytes), and if the answer does
    not appear, send again - exactly what a ground loop does when a
    reply is lost."""
    for _ in range(attempts):
        high = 0
        for _ in range(100_000):
            await RisingEdge(dut.clk)
            await ReadOnly()
            high = high + 1 if int(dut.uart_tx_o.value) == 1 else 0
            if high >= 300:
                break
        if cmd is not None:
            await uart_send(dut, cmd)
        for _ in range(30):
            b = await uart_capture(dut, 30_000)
            if b == target:
                return True
            if b is None:
                break                     # lost alignment or silence: resend
            if b == 0x5A:
                b2 = await uart_capture(dut, 4000)
                if b2 == target:
                    return True
                if b2 == 0x33:
                    for _ in range(18):
                        await uart_capture(dut, 4000)
    return False


async def hunt_z_flood(dut, tries=40):
    """A lone 0x5A proves nothing: the telemetry engine free-runs and
    its frame header opens with 0x5A too - a hunt that accepts one
    byte would pass over a dead CPU (found the hard way at gate level,
    Cycle 19). The loaded program FLOODS the pin with 'Z' back to
    back; a frame follows its sync with 0x33 and falls silent for
    2^INTERVAL_LOG2 cycles. Three 0x5A in a row is a living program."""
    for _ in range(tries):
        b = await uart_capture(dut, 80_000)
        if b == 0x5A:
            if await uart_capture(dut, 2_000) == 0x5A and \
               await uart_capture(dut, 2_000) == 0x5A:
                return True
    return False


@cocotb.test()
async def test_isp_loads_and_the_program_speaks(dut):
    """Stream a valid image over the UART pin: the loader commits it,
    the CPU runs from the bank, and the LOADED program's 'Z' stream
    appears on the TX pin - arbitrary code, written after tape-out,
    audible from outside the die."""
    await start(dut, strap=1)

    for b in image(PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "valid image must commit"
    assert int(dut.evt_boot_reject_o.value) == 0

    # the loaded loop must speak: hunt for the 'Z' FLOOD on the pin
    assert await hunt_z_flood(dut), "loaded program's 'Z' flood never came"


@cocotb.test()
async def test_corrupt_image_falls_back_to_rom(dut):
    """The same stream with a wrong CRC: refused at the read-back
    boundary, bank never selected, and the golden ROM firmware boots
    instead - proven by its echo answering on the pins."""
    await start(dut, strap=1)

    for b in image(PROGRAM, crc=0xDEADBEEF):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 0, "corrupt image must never run"

    # ROM fallback: give the bit-serial CPU its boot time, then echo
    await ClockCycles(dut.clk, 240_000)
    ok = await hunt_echo(dut, 0x41, 0x42)
    assert ok, "ROM fallback never echoed after reject"


@cocotb.test()
async def test_golden_strap_is_yesterdays_chip(dut):
    """Strap low: no loader, ROM boot, the imported cluster behaves as
    its own suite proved - echo b+1 through the pins."""
    await start(dut, strap=0)

    await ClockCycles(dut.clk, 240_000)
    ok = await hunt_echo(dut, 0x41, 0x42)
    assert ok, "golden-strap ROM echo never appeared"


# the bank prober: write a pattern to the sliced bank at 0x4000, read it
# back through the corrected port, and emit a byte on the UART that is
# 'Z' ONLY if the readback matched (t2 + ('Z' - 0xA5) == 'Z' iff t2 ==
# 0xA5). A broken bank shouts a different byte; a dead one says nothing.
BANK_BASE = 0x4000
PROBE = [
    lui(5, BANK_BASE >> 12),      # t0 = 0x4000
    addi(6, 0, 0xA5),             # t1 = pattern
    # Cycle 17: code runs FROM this bank now - probe word 256, well
    # past any test image, never the probe's own instructions
    sw(6, 5, 0x400),              # bank[word 256] = 0xA5
    lw(7, 5, 0x400),              # read back (corrected port)
    addi(7, 7, 0x5A - 0xA5),      # t2 += 'Z' - pattern
    lui(8, UART_BASE >> 12),      # t3 = 0x2000
    sw(7, 8, 4),                  # UART_TXDATA = t2
    jal(0, -8),                   # keep shouting the verdict
]


@cocotb.test()
async def test_loaded_code_uses_the_sliced_bank(dut):
    """Rung 4: the five-macro SECDED bank is CPU data memory. A loaded
    program writes it, reads it back through the corrected port, and
    reports the verdict on the TX pin: 'Z' means the round trip
    matched. The bank the beam campaign will scrub is now the bank the
    software actually uses."""
    await start(dut, strap=1)

    for b in image(PROBE):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "probe image must commit"

    # the prober floods its verdict byte; only a 'Z' FLOOD counts (a
    # lone 0x5A can be a telemetry frame sync - Cycle 19's lesson)
    assert await hunt_z_flood(dut), "bank-probe 'Z' flood never came"


# rung 5: 64 KB behind the 4 KB window. The program pages via the
# doorway's PAGE register (0x500C), proves pages hold DIFFERENT data
# (write 0xAA to page 2, 0xBB to page 3, read both back), and shouts
# the two verdicts forever: 0xB5 iff page 2 kept its word, 0xB6 iff
# page 3 kept its - a cross-page clobber would shout 0xC6 instead.
PAGED = [
    lui(5, 0x5),                  # t0 = 0x5000 (doorway)
    lui(8, 0x4),                  # t3 = 0x4000 (bank window)
    lui(9, 0x2),                  # s1 = 0x2000 (uart)
    addi(6, 0, 2), sw(6, 5, 0x0C),
    addi(7, 0, 0xAA), sw(7, 8, 0),
    addi(6, 0, 3), sw(6, 5, 0x0C),
    addi(7, 0, 0xBB), sw(7, 8, 0),
    # loop head (index 11): page 2 verdict
    addi(6, 0, 2), sw(6, 5, 0x0C),
    lw(7, 8, 0), addi(7, 7, 0xB5 - 0xAA),
    lw(14, 9, 0), andi(14, 14, 1), beq(14, 0, -8),   # poll TX_FREE
    sw(7, 9, 4),
    addi(15, 0, 300), addi(15, 15, -1), bne(15, 0, -4),  # idle gap
    # page 3 verdict
    addi(6, 0, 3), sw(6, 5, 0x0C),
    lw(7, 8, 0), addi(7, 7, 0xB6 - 0xBB),
    lw(14, 9, 0), andi(14, 14, 1), beq(14, 0, -8),
    sw(7, 9, 4),
    addi(15, 0, 300), addi(15, 15, -1), bne(15, 0, -4),
    jal(0, (11 - 31) * 4),
]


@cocotb.test()
async def test_pages_are_real_memory(dut):
    """Rung 5: the storage leg. Two pages of the 64 KB bank hold two
    different words at the same window address; the loaded program
    pages between them and reports both readbacks on the pin. 0xB5
    then 0xB6 means 64 KB is real, isolated memory - not one page
    aliased sixteen times."""
    await start(dut, strap=1)

    for b in image(PAGED):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "paging program must commit"

    ok = await hunt_echo(dut, None, 0xB5)
    assert ok, "page 2 verdict never arrived (or cross-page clobber)"
    ok = await hunt_echo(dut, None, 0xB6)
    assert ok, "page 3 verdict never arrived (or cross-page clobber)"


async def capture_frame(dut, timeout, tries=8):
    """Return a clean, checksum-valid 20-byte v2 frame from the shared
    UART. Each try SCANS the stream for a 0x5A 0x33 sync pair (the
    firmware's occasional bytes interleave, so the sync is ~one frame
    apart), collects 18 more bytes, and accepts only if the XOR checksum
    holds; a desync discards the try and scans again."""
    for _ in range(tries):
        # scan for the sync pair (up to ~3 frames' worth of bytes)
        got_sync = False
        for _ in range(64):
            b0 = await uart_capture(dut, timeout)
            if b0 != 0x5A:      # None (desync in a busy stream) or non-sync:
                continue        # keep scanning, do not mistake it for silence
            b1 = await uart_capture(dut, 4000)
            if b1 == 0x33:
                got_sync = True
                break
        if not got_sync:
            continue
        f = [0x5A, 0x33]
        for _ in range(18):
            f.append(await uart_capture(dut, 4000))
        if None in f:
            continue
        chk = 0
        for b in f[:19]:
            chk ^= b
        if f[19] == chk:
            return f
    return None


@cocotb.test()
async def test_telemetry_frames_carry_a_living_cpu(dut):
    """The last rung's telemetry half: with the golden ROM running, an
    unprompted v2 frame arrives on the shared UART with a valid XOR
    checksum and a NONZERO, CHANGING CPU signature - the housekeeping
    counters and the framer, on this die's own composition."""
    await start(dut, strap=0)
    await ClockCycles(dut.clk, 240_000)   # let the CPU reach its loop

    f1 = await capture_frame(dut, 200_000)
    assert f1 is not None, "no valid telemetry frame arrived"
    assert f1[15] != 0, "CPU signature zero - firmware never reached hk"

    # the signature must MOVE across frames - capture a few and check any
    # differs (the frames are ~8k cycles apart, the sig changes per loop)
    sigs = {f1[15]}
    for _ in range(4):
        f = await capture_frame(dut, 200_000)
        if f is not None:
            sigs.add(f[15])
    assert len(sigs) > 1, f"CPU signature frozen across frames: {sigs}"


# the MBIST runner (F28): start the bank's march test through the slot-5
# doorway, then shout the verdict forever. CTRL reads {busy, pass} in its
# top two bits, so (CTRL >> 30) is 1 exactly when the test is done and
# clean. The verdict base is 0xB0 - a byte family that never appears in
# early telemetry frames (sync 0x5A/0x33, zero counters, 0x69 checksum),
# so the shared TX cannot fake a verdict: 0xB1 done-pass, 0xB2/0xB3
# busy, 0xB0 done-FAIL - no branches, SERV-friendly.
MBIST_BASE = 0x5000
MBIST_RUN = [
    lui(5, MBIST_BASE >> 12),     # t0 = 0x5000
    lui(9, 0x3),                  # s1 = 0x3000 (housekeeping)
    lui(8, UART_BASE >> 12),      # t3 = 0x2000
    # march unit is the 16 KB INSTANCE - select instance 1 (page 4),
    # far from the instance the fetch path is standing on
    addi(6, 0, 4), sw(6, 5, 0x0C),
    addi(6, 0, 1), sw(6, 5, 0),   # CTRL = start, mode 0 (march c-)
    # loop (index 7): pet the watchdog, poll, shout the verdict - a
    # manufacturing runner keeps its computer alive while it tests
    sw(6, 9, 8),                  # CPU_SIG write: signon + wd clear
    lw(7, 5, 0),                  # {busy, pass, ...}
    srli(7, 7, 30),
    addi(7, 7, 0xB0),             # 0xB1 iff done-and-pass
    sw(7, 8, 4),                  # UART_TXDATA = verdict
    jal(0, (7 - 12) * 4),         # forever
]


@cocotb.test()
async def test_mbist_runs_from_loaded_software(dut):
    """F28: the manufacturing-test program is data too. An ISP-loaded
    runner starts the bank's march c- through the slot-5 doorway, polls
    the busy bit, and reports the verdict on the TX pin: 0xB1 means the
    march finished and the five-macro array is clean. 0xB0 would mean a
    finished, FAILING test and must never appear."""
    await start(dut, strap=1)

    for b in image(MBIST_RUN):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "MBIST runner must commit"

    # the march owns the array for ~21.5k cycles and the runner shouts
    # busy verdicts (0xB2/0xB3) the whole time, interleaved with
    # telemetry - be patient enough to outlast the stream, not just the
    # silence
    for _ in range(1500):
        b = await uart_capture(dut, 80_000)
        assert b != 0xB0, "MBIST finished FAILING on a clean array"
        if b == 0xB1:
            break
    else:
        raise AssertionError("MBIST pass verdict never reached the pin")


@cocotb.test()
async def test_watchdog_reverts_a_silent_bank(dut):
    """The watchdog-revert signon: load a program that NEVER writes the
    signature (never signs on). After a full watchdog period the loader
    must fail the bank and fall back to the golden ROM, whose echo then
    answers - the revert ladder, proven on this die."""
    # a program that just spins, never touching hk (no sign-on)
    SILENT = [addi(0, 0, 0), jal(0, -4)]
    await start(dut, strap=1)
    for b in image(SILENT):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)
    assert int(dut.boot_sel_o.value) == 1, "silent image must first commit"

    # give it more than one watchdog period (WD_LIMIT_LOG2=15 in the
    # makefile -> 2^15 cycles) for the verdict to land and revert
    for _ in range(80):
        await ClockCycles(dut.clk, 40_000)
        if int(dut.boot_sel_o.value) == 0:
            break
    else:
        raise AssertionError("watchdog never reverted the silent bank")

    # golden ROM is back: its echo answers
    await ClockCycles(dut.clk, 200_000)
    ok = await hunt_echo(dut, 0x41, 0x42)
    assert ok, "ROM echo never answered after revert"
