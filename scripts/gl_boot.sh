#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - the TMR'd-core GATE-LEVEL boot proof (Cycle 19)
#
# The stitcher was proven on a 16-flop LFSR carrier; the boot story was
# proven on RTL. This script closes the gap between those two proofs:
# the SAME netlist family that closed 50 MHz in P&R - zirh_vex_wrap,
# icache on RM 2P macros, SG13G2 cells - is stitched flop-by-flop with
# voted-feedback TMR and dropped into the otherwise-RTL zirh3_top, and
# the full ISP boot story runs against the gates:
#
#   [1/6] bind    - icache arrays onto RM 2P macros (vexlite_bind.sh)
#   [2/6] gates   - full synth of zirh_vex_wrap around the bound core;
#                   coverage guard: every flop is a stitchable type
#   [3/6] base    - UNstitched gate netlist boots (isolates the cell-
#                   model mix from the stitch before both are in play)
#   [4/6] stitch  - tmr_stitch.py; guard: stitched count == flop count
#   [5/6] boot    - the stitched netlist boots the same story clean
#   [6/6] wound   - replica rail B of EVERY flop is forced wrong for
#                   the whole boot: the vote must carry the machine,
#                   the release must heal every replica, and the
#                   program must still be speaking afterwards
#
# The stdcell models ship simulator-hostile (function behind specify-
# block delayed_* nets, X under iverilog) - the sed derivation below is
# the same cure dft_scan.sh and tmr_pilot.sh carry.
#
#   PDK_ROOT=... bash scripts/gl_boot.sh [bind|gates|base|stitch|boot|wound|all]
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/test/sim_build/gl_boot"
STAGE="${1:-all}"

: "${PDK_ROOT:?set PDK_ROOT to the ciel-managed PDK}"
LIB="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"
CELLS_V="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog"
SV="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_sram/verilog"

mkdir -p "${BUILD}"

# the 2P wrappers reference behavioral cores that live in the _ideal files
RM2P="${SV}/RM_IHPSG13_2P_512x32_c2_bm_bist.v ${SV}/RM_IHPSG13_2P_64x32_c2.v ${SV}/RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v ${SV}/RM_IHPSG13_2P_core_behavioral_ideal.v"
GL_SOURCES_BASE="${BUILD}/vexwrap_gates.v ${BUILD}/cells_func.v ${CELLS_V}/sg13g2_udp.v ${RM2P}"
GL_SOURCES_TMR="${BUILD}/vexwrap_tmr.v ${BUILD}/cells_func.v ${CELLS_V}/sg13g2_udp.v ${RM2P}"

case "${STAGE}" in
    bind|gates|base|stitch|boot|wound|all) ;;
    *) echo "unknown stage '${STAGE}'"; exit 1;;
esac

run_stage() { case "${STAGE}" in "$1"|all) return 0;; *) return 1;; esac; }

if run_stage bind; then
    echo "[1/6] binding the icache arrays onto RM 2P macros"
    bash "${ROOT}/scripts/vexlite_bind.sh" "${BUILD}/vexlite_bound.v"
fi

if run_stage gates; then
    echo "[2/6] full synthesis: zirh_vex_wrap around the bound core"
    cat > "${BUILD}/gates.ys" <<EOF
read_verilog -lib -DFUNCTIONAL ${SV}/RM_IHPSG13_2P_512x32_c2_bm_bist.v ${SV}/RM_IHPSG13_2P_64x32_c2.v
read_verilog ${BUILD}/vexlite_bound.v
read_verilog ${ROOT}/src/zirh_vex_wrap.v
hierarchy -top zirh_vex_wrap
synth -top zirh_vex_wrap -flatten
attrmap -modattr -remove keep_hierarchy
flatten
opt_clean
dfflibmap -liberty ${LIB}
abc -liberty ${LIB}
opt_clean
stat -liberty ${LIB}
write_json ${BUILD}/vexwrap_gates.json
write_verilog -noattr ${BUILD}/vexwrap_gates.v
EOF
    yosys -q -s "${BUILD}/gates.ys" 2>&1 | tee "${BUILD}/gates.log"

    # coverage guard: a flop the stitcher cannot see is a flop the vote
    # cannot protect - the netlist must be made ONLY of stitchable types
    GL_JSON="${BUILD}/vexwrap_gates.json" GL_FLOPS="${BUILD}/flops.txt" python3 - <<'PYEOF'
import json, os, re, sys
d = json.load(open(os.environ["GL_JSON"]))
mod = max(d["modules"].values(), key=lambda m: len(m.get("cells", {})))
stitchable = {"sg13g2_dfrbp_1", "sg13g2_dfrbp_2", "sg13g2_dfrbpq_1", "sg13g2_dfrbpq_2"}
seq = {}
for c in mod["cells"].values():
    t = c["type"]
    if re.match(r"^sg13g2_.*(df|dl|lg)", t):
        seq[t] = seq.get(t, 0) + 1
rogue = {t: n for t, n in seq.items() if t not in stitchable}
total = sum(n for t, n in seq.items() if t in stitchable)
if rogue:
    print(f"COVERAGE: FAIL - unstitchable sequential cells: {rogue}")
    sys.exit(1)
open(os.environ["GL_FLOPS"], "w").write(str(total))
print(f"COVERAGE: PASS - {total} flops, all stitchable types")
PYEOF

    N_RM=$(grep -c "RM_IHPSG13_2P" "${BUILD}/vexwrap_gates.v" || true)
    if [ "${N_RM}" -ne 2 ]; then
        echo "MACROS: FAIL - expected 2 RM 2P instances after flatten, found ${N_RM}"
        exit 1
    fi
    echo "MACROS: PASS - both icache macros survived the flatten"
fi

if run_stage base; then
    echo "[3/6] baseline: the UNstitched gate netlist boots the ISP story"
    # foundry stdcell models drive function through specify-block
    # delayed_* nets - X under iverilog; derive the functional copy
    sed -e '/specify/,/endspecify/d' \
        -e '/^\s*wire\s\+delayed_/d' \
        -e 's/delayed_//g' \
        "${CELLS_V}/sg13g2_stdcell.v" > "${BUILD}/cells_func.v"
    COCOTB_TEST_FILTER=test_isp_loads_and_the_program_speaks \
        make -C "${ROOT}/test" -B -f Makefile.top \
        CPU_SOURCES="${GL_SOURCES_BASE}" SIM_BUILD=sim_build/gl_base
    echo "GL_BASE: PASS - gates + macro models + RTL rest boot together"
fi

if run_stage stitch; then
    echo "[4/6] stitching: voted-feedback TMR over every flop"
    python3 "${ROOT}/scripts/tmr_stitch.py" \
        "${BUILD}/vexwrap_gates.json" "${BUILD}/vexwrap_tmr.json" \
        | tee "${BUILD}/stitch.log"
    N_TMR=$(grep -oE 'TMR [0-9]+ flops' "${BUILD}/stitch.log" | grep -oE '[0-9]+')
    N_FLOPS=$(cat "${BUILD}/flops.txt")
    if [ "${N_TMR}" != "${N_FLOPS}" ]; then
        echo "STITCH: FAIL - ${N_TMR} stitched of ${N_FLOPS} flops"
        exit 1
    fi
    echo "STITCH: PASS - all ${N_TMR} flops carry a voter"
    yosys -q -p "read_json ${BUILD}/vexwrap_tmr.json; write_verilog -noattr ${BUILD}/vexwrap_tmr.v"
fi

if run_stage boot; then
    echo "[5/6] the stitched netlist boots the same story, clean"
    COCOTB_TEST_FILTER=test_isp_loads_and_the_program_speaks \
        make -C "${ROOT}/test" -B -f Makefile.top \
        CPU_SOURCES="${GL_SOURCES_TMR}" SIM_BUILD=sim_build/gl_tmr
    echo "GL_BOOT: PASS - the TMR'd core boots at gate level"
fi

if run_stage wound; then
    echo "[6/6] the wound: replica rail B dead for the whole boot"
    N_TMR=$(grep -oE 'TMR [0-9]+ flops' "${BUILD}/stitch.log" | grep -oE '[0-9]+')
    GL_TMR_N="${N_TMR}" \
        make -C "${ROOT}/test" -B -f Makefile.top \
        CPU_SOURCES="${GL_SOURCES_TMR}" COCOTB_TEST_MODULES=test_top_gl \
        SIM_BUILD=sim_build/gl_wound
    echo "GL_WOUND: PASS - the vote carried the boot, the release healed the rail"
fi

echo "GL_BOOT_PROOF: DONE (${STAGE})"
