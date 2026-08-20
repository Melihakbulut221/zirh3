# =============================================================================
# ZIRH-3 - the SEU rain campaign (Cycle 24)
#
# The wound trio (test_top_gl) kills a whole replica rail for the
# whole boot - a proof by overkill. This bench models what orbit
# actually delivers: SINGLE upsets, one replica of one flop at one
# random moment, landing while the machine is busy. Each shot forces
# the replica net to its inverse for exactly one clock (a real SEU's
# persistence under voted feedback is one cycle: the next edge
# reloads the voted word), verifies the wound BIT (the forced value
# is visible on the net - a shot that does not land proves nothing),
# releases, and two clocks later checks the triple agrees again.
#
# The boot story runs to completion under the rain: the image must
# commit, no reject, and the program's 'Z' flood must be alive at the
# end. A minimum shot count keeps the rain from passing hollow-thin.
#
# GL_TMR_N carries the flop count; GL_SEU_SEED picks the storm.
# =============================================================================

import os
import random

import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles

from test_top_isp import PROGRAM, hunt_z_flood, image, start, uart_send


@cocotb.test()
async def test_boot_shrugs_off_the_seu_rain(dut):
    n = int(os.environ["GL_TMR_N"])
    seed = int(os.environ.get("GL_SEU_SEED", "1"))
    rng = random.Random(seed)
    core = dut.u_soc.u_cpu
    rails = {r: [core._id(f"tmr{r}_{i}", extended=False) for i in range(n)]
             for r in "ABC"}

    stats = {"shots": 0, "healed": 0, "skipped_x": 0,
             "per_rail": {"A": 0, "B": 0, "C": 0}}
    done = [False]

    async def rain():
        while not done[0]:
            await ClockCycles(dut.clk, rng.randrange(60, 180))
            if done[0]:
                return
            # unreset datapath flops read X until first written - an X
            # pick costs a redraw, not a rain slot (measured: 53 of 66
            # slots lost to X with the naive draw, 13 shots, gate red)
            sig = None
            for _ in range(20):
                r = rng.choice("ABC")
                i = rng.randrange(n)
                v = str(rails[r][i].value)
                if v in ("0", "1"):
                    sig = rails[r][i]
                    break
                stats["skipped_x"] += 1
            if sig is None:
                continue
            flipped = 1 - int(v)
            sig.value = Force(flipped)
            await ClockCycles(dut.clk, 1)
            assert str(sig.value) == str(flipped), \
                f"shot at {r}_{i} never landed - the rain is fake"
            sig.value = Release()
            await ClockCycles(dut.clk, 2)
            trip = [str(rails[q][i].value) for q in "ABC"]
            assert trip[0] == trip[1] == trip[2], \
                f"flop {i} triple {trip} never re-agreed after {r} was hit"
            stats["shots"] += 1
            stats["healed"] += 1
            stats["per_rail"][r] += 1

    storm = cocotb.start_soon(rain())

    await start(dut, strap=1)
    for b in image(PROGRAM):
        await uart_send(dut, b)
    await ClockCycles(dut.clk, 500)

    assert int(dut.boot_sel_o.value) == 1, "under rain: image must commit"
    assert int(dut.evt_boot_reject_o.value) == 0

    assert await hunt_z_flood(dut), "under rain: the flood never came"

    done[0] = True
    await ClockCycles(dut.clk, 2)
    storm.kill()

    dut._log.info(
        f"SEU RAIN: {stats['shots']} shots (A/B/C = "
        f"{stats['per_rail']['A']}/{stats['per_rail']['B']}/"
        f"{stats['per_rail']['C']}), {stats['healed']} healed, "
        f"{stats['skipped_x']} skipped on X, seed {seed}")
    assert stats["shots"] >= 40, \
        f"only {stats['shots']} shots - the rain was too thin to prove anything"
    assert stats["healed"] == stats["shots"]
