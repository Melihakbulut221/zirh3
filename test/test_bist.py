# ZIRH P2 - the march/BIST engine: screening, fill and the beam scan.
import cocotb
import fsm_cov
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, NextTimeStep, ReadOnly, RisingEdge


async def bus_write(dut, adr, dat):
    await NextTimeStep()
    dut.cyc_i.value = 1
    dut.adr_i.value = adr
    dut.we_i.value = 1
    dut.dat_i.value = dat
    dut.sel_i.value = 0xF
    for _ in range(16):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.ack_o.value) == 1:
            break
    await NextTimeStep()
    dut.cyc_i.value = 0
    await RisingEdge(dut.clk)


async def run_bist(dut, mode, timeout=200_000):
    await NextTimeStep()
    dut.bist_mode_i.value = mode
    dut.bist_start_i.value = 1
    await ClockCycles(dut.clk, 2)
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        await ReadOnly()
        done = int(dut.bist_busy_o.value) == 0
        if done:
            res = (int(dut.bist_pass_o.value),
                   int(dut.bist_fail_cnt_o.value),
                   int(dut.bist_fail_adr_o.value),
                   int(dut.bist_fail_map_o.value))
        await NextTimeStep()
        if done:
            break
    else:
        raise AssertionError("bist never finished")
    dut.bist_start_i.value = 0
    await ClockCycles(dut.clk, 3)
    return res


@cocotb.test()
async def test_bist_engine(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    _cov = fsm_cov.watch(dut, dut.u_bist.st_q, "bist")
    dut.cyc_i.value = 0
    dut.scrub_en_i.value = 0
    dut.bist_start_i.value = 0
    dut.bist_mode_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # 1. MARCH C- on a healthy array: pass, zero fails
    p, cnt, _, _ = await run_bist(dut, 0)
    assert p == 1 and cnt == 0, f"march on healthy array: pass={p} cnt={cnt}"

    # 2. checkerboard fill, then read-scan: clean
    p, cnt, _, _ = await run_bist(dut, 1)
    assert p == 1, "cb fill must pass"
    p, cnt, _, _ = await run_bist(dut, 2)
    assert p == 1 and cnt == 0, f"scan after fill: pass={p} cnt={cnt}"

    # 3. disturb one row through the FUNCTIONAL port (writes a SECDED
    # codeword over the checkerboard) - the scan must FAIL, count it,
    # and latch the address; and it must NOT repair (a second scan
    # still sees it - the beam counter never erases its own event)
    victim = 0x155
    await bus_write(dut, victim << 2, 0x00C0FFEE)
    p, cnt, adr, fmap = await run_bist(dut, 2)
    assert p == 0 and cnt >= 1, f"scan missed the disturbance: {p},{cnt}"
    assert adr == victim, f"fail address {adr:#x} != {victim:#x}"
    assert fmap != 0, "fail map empty"
    p2, cnt2, adr2, _ = await run_bist(dut, 2)
    assert p2 == 0 and cnt2 >= 1 and adr2 == victim, (
        "scan repaired the array - the beam experiment just lost its event")

    # 4. march after the disturbance: rewrites everything, ends clean
    p, cnt, _, _ = await run_bist(dut, 0)
    assert p == 1 and cnt == 0, "march must screen clean after rewrite"

    fsm_cov.dump("bist", _cov)
    dut._log.info("bist: march clean, cb+scan clean, scan detects and "
                  "preserves a disturbance at the right address, march "
                  "rescreens clean")
