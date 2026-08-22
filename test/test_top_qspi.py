# =============================================================================
# ZIRH-3 - autonomous MRAM boot through the whole die (Cycle 38)
#
# NOT ONE UART BYTE flows in this test. PORTA 31 is held high at
# reset, so the die samples its image source as external MRAM and
# streams the boot image itself over the four-pin x1 QSPI leg on
# PORTA 30..27 - the bench is the MRAM, a mode-0 slave serving the
# same framed image the ISP tests push by hand. The loader's
# contract (framing, CRC, one ruling) is untouched; only the
# transport moved. The verdict is the program's own Z flood.
# =============================================================================

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_top_fuzz import z_signature
from test_top_isp import addi, image, jal, lui, start, sw

QPROGRAM = [
    lui(10, 0x2),
    addi(11, 0, 0x5A),
    sw(11, 10, 4),
    jal(0, -4),
]


@cocotb.test()
async def test_the_die_boots_itself_from_mram(dut):
    await start(dut, strap=1)
    dut.gpio_a_i.value = 1 << 31          # image source: MRAM

    img = list(image(QPROGRAM))
    st = {"bits": [], "sending": False, "bitpos": 7, "byte": 0, "prev": 0}

    async def mram():
        while True:
            await RisingEdge(dut.clk)
            oe = int(dut.gpio_a_oe.value)
            o = int(dut.gpio_a_o.value)
            csn = (o >> 27) & 1 if (oe >> 27) & 1 else 1
            sck = (o >> 28) & 1 if (oe >> 28) & 1 else 0
            io0 = (o >> 29) & 1 if (oe >> 29) & 1 else 0
            if csn:
                st["bits"] = []
                st["sending"] = False
                st["bitpos"] = 7
                st["byte"] = 0
                st["prev"] = sck
                continue
            if sck and not st["prev"]:            # rising: command in
                if not st["sending"]:
                    st["bits"].append(io0)
                    if len(st["bits"]) == 32:     # cmd + 24-bit addr
                        cmd = sum(b << (31 - i)
                                  for i, b in enumerate(st["bits"])) >> 24
                        assert cmd == 0x03, f"x1 READ expected, got {cmd:#x}"
                        st["sending"] = True
                        st["byte"] = 0
                        st["bitpos"] = 7
            if (not sck) and st["prev"]:          # falling: data out
                if st["sending"] and st["byte"] < len(img):
                    bit = (img[st["byte"]] >> st["bitpos"]) & 1
                    v = int(dut.gpio_a_i.value) & ~(1 << 30)
                    dut.gpio_a_i.value = v | (bit << 30)
                    if st["bitpos"] == 0:
                        st["bitpos"] = 7
                        st["byte"] += 1
                    else:
                        st["bitpos"] -= 1
            st["prev"] = sck

    cocotb.start_soon(mram())

    for _ in range(300):
        await ClockCycles(dut.clk, 200)
        if int(dut.boot_sel_o.value) == 1:
            break
    assert int(dut.boot_sel_o.value) == 1, \
        "the die must commit an image it fetched itself"
    assert await z_signature(dut), \
        "the self-booted program must speak"

    # the ruling must RELEASE the transport: a reader left emitting
    # would hold CS low forever and keep four PORTA pins hostage
    await ClockCycles(dut.clk, 2000)
    oe = int(dut.gpio_a_oe.value)
    assert (oe >> 27) & 0xF == 0, \
        "after the ruling the QSPI pins must return to the GPIO block"
    assert int(dut.u_qspi.cs_n_o.value) == 1, "and the MRAM must be released"
    assert int(dut.u_qspi.busy_o.value) == 0, "the reader must be idle"
