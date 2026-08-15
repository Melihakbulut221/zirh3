# =============================================================================
# ZIRH-3 - post-synthesis scan stitcher (F28 rehearsal)
# scripts/dft_scan_stitch.py
#
# Reads a yosys JSON netlist mapped to SG13G2 cells, swaps every plain
# flop for its scan equivalent, and stitches one scan chain through
# them in deterministic (name-sorted) order:
#
#   sg13g2_dfrbp_N  -> sg13g2_sdfrbp_N    (Q + Q_N flops)
#   sg13g2_dfrbpq_N -> sg13g2_sdfrbpq_N   (Q-only flops)
#
# New top-level ports: scan_en_i (SCE of every flop), scan_si_i (SCD of
# the first), scan_so_o (Q of the last). The RTL is never touched -
# this is the tool-side path a dedicated die takes to full scan, run
# here on one pilot block to prove the flow end to end.
#
# Usage: python3 dft_scan_stitch.py in.json out.json
# Prints "CHAIN <n>" on success.
# =============================================================================

import json
import sys

SCAN_MAP = {
    "sg13g2_dfrbp_1":  "sg13g2_sdfrbp_1",
    "sg13g2_dfrbp_2":  "sg13g2_sdfrbp_2",
    "sg13g2_dfrbpq_1": "sg13g2_sdfrbpq_1",
    "sg13g2_dfrbpq_2": "sg13g2_sdfrbpq_2",
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

    # allocate fresh bit ids above everything in use
    used = set()
    for port in mod.get("ports", {}).values():
        used.update(b for b in port["bits"] if isinstance(b, int))
    for cell in mod.get("cells", {}).values():
        for bits in cell.get("connections", {}).values():
            used.update(b for b in bits if isinstance(b, int))
    nxt = max(used) + 1 if used else 2
    bit_se, bit_si = nxt, nxt + 1

    flops = sorted(n for n, c in mod["cells"].items() if c["type"] in SCAN_MAP)
    if not flops:
        print("ERROR: no mappable flops found", file=sys.stderr)
        return 1

    prev_q = bit_si
    for name in flops:
        cell = mod["cells"][name]
        cell["type"] = SCAN_MAP[cell["type"]]
        cell["connections"]["SCE"] = [bit_se]
        cell["connections"]["SCD"] = [prev_q]
        if "port_directions" in cell:
            cell["port_directions"]["SCE"] = "input"
            cell["port_directions"]["SCD"] = "input"
        prev_q = cell["connections"]["Q"][0]

    mod["ports"]["scan_en_i"] = {"direction": "input", "bits": [bit_se]}
    mod["ports"]["scan_si_i"] = {"direction": "input", "bits": [bit_si]}
    mod["ports"]["scan_so_o"] = {"direction": "output", "bits": [prev_q]}
    mod.setdefault("netnames", {})
    mod["netnames"]["scan_en_i"] = {"bits": [bit_se], "hide_name": 0}
    mod["netnames"]["scan_si_i"] = {"bits": [bit_si], "hide_name": 0}

    with open(outp, "w") as f:
        json.dump(design, f)

    print(f"CHAIN {len(flops)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
