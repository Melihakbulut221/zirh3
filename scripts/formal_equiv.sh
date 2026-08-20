#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - RTL-vs-stitched formal equivalence (Cycle 28)
#
# Two theorems, decomposed honestly:
#
#   [pilot] the FULL chain at carrier scale: the RTL LFSR against its
#           synthesized-and-stitched netlist - RTL elaboration, abc
#           mapping and the stitcher all inside one proof. The
#           carrier's whole state is port-visible, so the ports are
#           the match points and induction closes over them.
#   [core]  the TRANSFORMATION at full scale: the pre-stitch gate
#           netlist against the stitched one, 2138 triples. Match
#           points come from the stitcher's own bookkeeping (flop N's
#           Q in gold, N__vor1's Y in gate); the RM macros are cut to
#           the boundary - both sides must drive them identically and
#           respond identically to anything they could say. The
#           synthesis leg at core scale stays simulation-validated
#           (the gl ladder boots both); this proof removes the
#           stitcher from the trusted base.
#
# The cell functions come from the PDK liberty via formal_eqlib.py -
# generated, not hand-written.
#
#   PDK_ROOT=... bash scripts/formal_equiv.sh [pilot|core|all]
#   (core needs gl_boot products; pilot needs a tmr_pilot build)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/test/sim_build/equiv"
STAGE="${1:-all}"

: "${PDK_ROOT:?set PDK_ROOT to the ciel-managed PDK}"
LIB="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"

mkdir -p "${BUILD}"

case "${STAGE}" in
    pilot|core|all) ;;
    *) echo "unknown stage '${STAGE}'"; exit 1;;
esac

run_stage() { case "${STAGE}" in "$1"|all) return 0;; *) return 1;; esac; }

cells_of() {  # union of sg13g2 cell types across the given jsons
    python3 - "$@" <<'PYEOF'
import json, sys
types = set()
for p in sys.argv[1:]:
    d = json.load(open(p))
    mod = max(d["modules"].values(), key=lambda m: len(m.get("cells", {})))
    for c in mod["cells"].values():
        if c["type"].startswith("sg13g2_"):
            types.add(c["type"])
print(" ".join(sorted(types)))
PYEOF
}

if run_stage pilot; then
    echo "[1/2] pilot: RTL LFSR vs its synthesized-and-stitched netlist"
    PJ="${ROOT}/test/sim_build/tmr_pilot"
    test -f "${PJ}/carrier_tmr.json" || {
        echo "missing pilot build - run scripts/tmr_pilot.sh first"; exit 1; }
    python3 "${ROOT}/scripts/formal_eqlib.py" "${LIB}" "${BUILD}/eqlib_pilot.v" \
        $(cells_of "${PJ}/carrier_tmr.json")
    python3 "${ROOT}/scripts/formal_eqprep.py" "${PJ}/carrier_tmr.json" \
        "${BUILD}/pilot_gate.json" gate
    timeout 900 yosys -p "
        read_verilog ${BUILD}/eqlib_pilot.v;
        read_verilog ${ROOT}/test/tmr_carrier.v;
        rename tmr_carrier gold;
        read_json ${BUILD}/pilot_gate.json;
        proc; async2sync; flatten gold; flatten gate; opt_clean;
        equiv_make gold gate merged;
        hierarchy -top merged;
        equiv_simple; equiv_induct;
        equiv_status -assert" 2>&1 | tee "${BUILD}/pilot.log"
    grep -aq "Equivalence successfully proven" "${BUILD}/pilot.log"
    NEQ=$(grep -aoE "Found [0-9]+ .equiv cells" "${BUILD}/pilot.log" | grep -oE "[0-9]+" | tail -1)
    echo "equiv points: ${NEQ} (>= 16 or the proof is vacuous)"
    test "${NEQ}" -ge 16
    echo "EQUIV PILOT: PASS - RTL to stitched gates, one proof, full chain"
fi

if run_stage core; then
    echo "[2/2] core: the stitch transformation at 2138 triples"
    GJ="${ROOT}/test/sim_build/gl_boot"
    test -f "${GJ}/vexwrap_tmr.json" || {
        echo "missing gl_boot products - run gl_boot.sh bind/gates/stitch"; exit 1; }
    python3 "${ROOT}/scripts/formal_eqlib.py" "${LIB}" "${BUILD}/eqlib_core.v" \
        $(cells_of "${GJ}/vexwrap_gates.json" "${GJ}/vexwrap_tmr.json")
    python3 "${ROOT}/scripts/formal_eqprep.py" "${GJ}/vexwrap_gates.json" \
        "${BUILD}/core_gold.json" gold
    python3 "${ROOT}/scripts/formal_eqprep.py" "${GJ}/vexwrap_tmr.json" \
        "${BUILD}/core_gate.json" gate
    timeout 3600 yosys -p "
        read_verilog ${BUILD}/eqlib_core.v;
        read_json ${BUILD}/core_gold.json;
        read_json ${BUILD}/core_gate.json;
        proc; async2sync; flatten gold; flatten gate; opt_clean;
        equiv_make gold gate merged;
        hierarchy -top merged;
        equiv_simple; equiv_induct;
        equiv_status -assert" 2>&1 | tee "${BUILD}/core.log"
    grep -aq "Equivalence successfully proven" "${BUILD}/core.log"
    NEQ=$(grep -aoE "Found [0-9]+ .equiv cells" "${BUILD}/core.log" | grep -oE "[0-9]+" | tail -1)
    echo "equiv points: ${NEQ} (>= 2138 or the proof is vacuous)"
    test "${NEQ}" -ge 2138
    echo "EQUIV CORE: PASS - the stitcher is out of the trusted base"
fi

echo "FORMAL_EQUIV: DONE (${STAGE})"
