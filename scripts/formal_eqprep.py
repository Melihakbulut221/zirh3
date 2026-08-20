# =============================================================================
# ZIRH-3 - equivalence preparation (Cycle 28)
#
# Takes the GOLD (pre-stitch) and GATE (stitched) yosys JSONs and
# makes them a provable pair:
#
#   CUT      the RM macros become ports: every macro input pin turns
#            into an observed output (both sides must drive the macro
#            identically), every macro output pin turns into a free
#            input (both sides must respond identically to anything
#            the macro could say) - the standard blackbox-equivalence
#            decomposition, sound by composition
#   MATCH    the stitcher kept every original flop's CELL NAME and
#            handed its Q net to the voter (__vor1's Y) - so the
#            match points need no name archaeology: flop N's Q bit in
#            gold and N__vor1's Y bit in gate both get the netname
#            eqp_<i>, i from the same sorted order on both sides
#   RENAME   the top module becomes 'gold' / 'gate' in the file, so
#            one yosys design can hold both without collision
#
#   python3 formal_eqprep.py <in.json> <out.json> gold|gate [floptype]
# =============================================================================

import json
import sys

MACROS = ("RM_IHPSG13_2P_512x32_c2_bm_bist", "RM_IHPSG13_2P_64x32_c2")


def main(inp, outp, side, flop="sg13g2_dfrbpq_1"):
    d = json.load(open(inp))
    name = max(d["modules"], key=lambda n: len(d["modules"][n].get("cells", {})))
    mod = d["modules"][name]
    cells = mod["cells"]
    ports = mod["ports"]
    nets = mod.setdefault("netnames", {})

    # CUT: macros out, their pins onto the boundary
    for cname in [c for c, cc in cells.items() if cc["type"] in MACROS]:
        cell = cells.pop(cname)
        leaf = cname.split(".")[-1]
        for pin, bits in cell["connections"].items():
            direction = cell["port_directions"][pin]
            # macro input pins are DRIVEN by the design: observe them;
            # macro output pins DRIVE the design: leave them free
            pdir = "output" if direction == "input" else "input"
            pname = f"eqcut_{leaf}_{pin}".replace("!", "")
            ports[pname] = {"direction": pdir, "bits": bits}
            nets[pname] = {"bits": bits, "hide_name": 0}

    # MATCH: one netname per flop boundary, same order both sides
    flops = sorted(c for c, cc in cells.items() if cc["type"] == flop
                 and not c.endswith("__B") and not c.endswith("__C"))
    made = 0
    for i, fname in enumerate(flops):
        if side == "gold":
            bit = cells[fname]["connections"]["Q"][0]
        else:
            voter = cells.get(fname + "__vor1")
            if voter is None:
                print(f"ERROR: no voter for {fname}", file=sys.stderr)
                return 1
            bit = voter["connections"]["X"][0]
        nets[f"eqp_{i}"] = {"bits": [bit], "hide_name": 0}
        made += 1

    d["modules"] = {side: mod}
    mod.setdefault("attributes", {})["top"] = 1
    json.dump(d, open(outp, "w"))
    print(f"eqprep[{side}]: {made} match points, macros cut, top renamed")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
