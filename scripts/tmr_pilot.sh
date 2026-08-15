#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - protection pilot B: tool-applied TMR, proven and measured
#
#   bash scripts/tmr_pilot.sh
#
# Two artifacts. FUNCTION: the carrier LFSR is synthesized to SG13G2
# cells, every flop tripled with voted feedback by tmr_stitch.py, and
# the stitched netlist proven against the golden RTL - including a
# pinned-replica masking test and the heal after release. AREA: the
# same transform applied to the VexRiscv_Lite netlist, with cell and
# flop counts before and after - the number the candidate comparison
# needs.
#
# Needs: yosys, iverilog, python3, PDK_ROOT with ihp-sg13g2.
# =============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/test/sim_build/tmr_pilot"
LIB="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"
CELLS_V="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog"

mkdir -p "${BUILD}"

echo "ZIRH-3 protection pilot B: tool-applied TMR"
echo "-------------------------------------------"

echo "[1/3] carrier: synth, stitch, prove"
yosys -q -p "
    read_verilog ${ROOT}/test/tmr_carrier.v;
    synth -top tmr_carrier -flatten;
    dfflibmap -liberty ${LIB};
    abc -liberty ${LIB};
    opt_clean;
    write_json ${BUILD}/carrier.json"
python3 "${ROOT}/scripts/tmr_stitch.py" \
    "${BUILD}/carrier.json" "${BUILD}/carrier_tmr.json"
yosys -q -p "
    read_json ${BUILD}/carrier_tmr.json;
    write_verilog -noattr ${BUILD}/carrier_tmr.v"

sed -e '/specify/,/endspecify/d' \
    -e '/^\s*wire\s\+delayed_/d' \
    -e 's/delayed_//g' \
    "${CELLS_V}/sg13g2_stdcell.v" > "${BUILD}/cells_func.v"

iverilog -g2012 -s tb_tmr_stitch -o "${BUILD}/stitch.vvp" \
    "${ROOT}/test/tb_tmr_stitch.v" \
    "${BUILD}/carrier_tmr.v" \
    "${BUILD}/cells_func.v" \
    "${CELLS_V}/sg13g2_udp.v"
vvp "${BUILD}/stitch.vvp" | tee "${BUILD}/stitch.log"
grep -q "TMRSTITCH: PASS" "${BUILD}/stitch.log"

echo "[2/3] the core: same transform, area measured"
yosys -q -p "
    read_verilog ${ROOT}/src/vex/VexRiscv_Lite.v;
    hierarchy -top VexRiscv;
    synth -top VexRiscv -flatten;
    dfflibmap -liberty ${LIB};
    abc -liberty ${LIB};
    opt_clean;
    tee -o ${BUILD}/vex_before.stat stat;
    write_json ${BUILD}/vex.json"
python3 "${ROOT}/scripts/tmr_stitch.py" \
    "${BUILD}/vex.json" "${BUILD}/vex_tmr.json"
yosys -q -p "
    read_json ${BUILD}/vex_tmr.json;
    tee -o ${BUILD}/vex_after.stat stat"

B=$(grep "Number of cells" "${BUILD}/vex_before.stat" | head -1 | awk '{print $NF}')
A=$(grep "Number of cells" "${BUILD}/vex_after.stat" | head -1 | awk '{print $NF}')
echo "[3/3] core cells before/after: ${B} -> ${A}"
echo "-------------------------------------------"
echo "PASS: stitched TMR proven on gates (function, mask, heal); core transform measured"
