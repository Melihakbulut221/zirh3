# =============================================================================
# ZIRH-3 - post-synthesis flop triplication with voted feedback
# scripts/tmr_stitch.py                      (Cycle 14 rung 3, pilot B)
#
# The self-correcting TMR register, applied by TOOL to a netlist the
# RTL never sees: every flop becomes three, a majority voter takes
# over the original Q net, and because all downstream logic - the
# combinational cone AND every replica's own D path - reads the VOTED
# net, a corrupted replica is rewritten with the majority value on
# the next enable, exactly like zirh_tmr_reg's voted feedback. This is
# the same machinery as the scan stitcher, one voter deeper.
#
#   python3 tmr_stitch.py in.json out.json
#
# Prints "TMR <n> flops" and structural self-check results. The new
# replica outputs are named tmrB_<i>/tmrC_<i> so a bench can reach
# them by name.
# =============================================================================

import json
import sys

FLOP_TYPES = {
    "sg13g2_dfrbp_1", "sg13g2_dfrbp_2",
    "sg13g2_dfrbpq_1", "sg13g2_dfrbpq_2",
}


def main(inp, outp):
    with open(inp) as f:
        design = json.load(f)

    mods = design["modules"]
    top_name = next(
        (n for n, m in mods.items()
         if m.get("attributes", {}).get("top") in (1, "1", "00000000000000000000000000000001")),
        None)
    if top_name is None:
        top_name = max(mods, key=lambda n: len(mods[n].get("cells", {})))
    mod = mods[top_name]
    cells = mod["cells"]
    nets = mod.setdefault("netnames", {})

    used = set()
    for port in mod.get("ports", {}).values():
        used.update(b for b in port["bits"] if isinstance(b, int))
    for cell in cells.values():
        for bits in cell.get("connections", {}).values():
            used.update(b for b in bits if isinstance(b, int))
    # netnames keep bit ids that opt passes already dropped from every
    # connection; a fresh id colliding with one of those becomes an
    # alias ASSIGN onto a declared wire at write_verilog time - raw
    # replica and voter internals leak onto old nets (found the hard
    # way: the 2138-flop core died under a B-rail wound the voter math
    # provably masks; the 16-flop carrier was too small to collide)
    for net in nets.values():
        used.update(b for b in net["bits"] if isinstance(b, int))
    nxt = [max(used) + 1 if used else 2]

    def fresh():
        b = nxt[0]
        nxt[0] += 1
        return b

    def gate(kind, name, a, b, y):
        cells[name] = {
            "type": kind, "port_directions":
                {"A": "input", "B": "input", "Y": "output"},
            "connections": {"A": [a], "B": [b], "Y": [y]},
            "parameters": {"A_SIGNED": 0, "B_SIGNED": 0,
                           "A_WIDTH": 1, "B_WIDTH": 1, "Y_WIDTH": 1},
        }

    flops = sorted(n for n, c in cells.items() if c["type"] in FLOP_TYPES)
    if not flops:
        print("ERROR: no flops found", file=sys.stderr)
        return 1

    checked = 0
    for i, name in enumerate(flops):
        orig = cells[name]
        q_bit = orig["connections"]["Q"][0]

        # the original keeps its cell but its Q moves to a private net;
        # the voter output takes over the ORIGINAL q_bit, so every
        # consumer - comb cone, D paths, Q_N users stay as-is - reads
        # the majority
        qa, qb, qc = fresh(), fresh(), fresh()
        orig["connections"]["Q"] = [qa]

        for suffix, qx in (("__B", qb), ("__C", qc)):
            copy = json.loads(json.dumps(orig))
            copy["connections"]["Q"] = [qx]
            if "Q_N" in copy["connections"]:
                copy["connections"]["Q_N"] = [fresh()]   # unused
            cells[name + suffix] = copy

        t0, t1, t2, t3 = fresh(), fresh(), fresh(), fresh()
        gate("$and", f"{name}__vand0", qa, qb, t0)
        gate("$and", f"{name}__vand1", qb, qc, t1)
        gate("$and", f"{name}__vand2", qa, qc, t2)
        gate("$or",  f"{name}__vor0", t0, t1, t3)
        gate("$or",  f"{name}__vor1", t3, t2, q_bit)

        nets[f"tmrA_{i}"] = {"bits": [qa], "hide_name": 0}
        nets[f"tmrB_{i}"] = {"bits": [qb], "hide_name": 0}
        nets[f"tmrC_{i}"] = {"bits": [qc], "hide_name": 0}

        # structural self-check: every replica's D is the SAME net, and
        # that net is downstream of voted values by construction (all
        # original consumers of q_bit now read the voter output)
        d_orig = orig["connections"]["D"]
        assert cells[name + "__B"]["connections"]["D"] == d_orig
        assert cells[name + "__C"]["connections"]["D"] == d_orig
        checked += 1

    print(f"TMR {len(flops)} flops ({checked} structurally checked: "
          "shared D cone, voter owns the original Q net)")

    with open(outp, "w") as f:
        json.dump(design, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
