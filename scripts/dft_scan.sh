#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - post-synthesis scan-insertion rehearsal (F28)
#
#   bash scripts/dft_scan.sh
#
# The dedicated-die path to full scan WITHOUT touching the proven RTL:
# synthesize a pilot block (zirh_clkobs) to real SG13G2 cells, swap
# every flop for its scan sibling, stitch one chain in deterministic
# order, and PROVE the stitched netlist by simulation - shift identity
# and a capture cycle, on the foundry's own cell models. The pilot is
# the clock-loss observer because its 48 flops cover both TMR replicas
# and plain state, and its suite already guards its function.
#
# Needs: yosys, iverilog, python3, PDK_ROOT with ihp-sg13g2.
# =============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/test/sim_build/dft_scan"
LIB="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"
CELLS_V="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog"

mkdir -p "${BUILD}"

echo "ZIRH-3 scan-insertion rehearsal (pilot: zirh_clkobs)"
echo "----------------------------------------------------"

echo "[1/3] synth to SG13G2 cells"
# keep_hierarchy is the RTL's merge-proof; scan stitching wants the
# final FLAT netlist, so the attribute comes off only after synth's
# opt passes have run against the boundaries. No opt_merge runs after
# the flatten - dfflibmap/abc/opt_clean touch no flop pairs - so the
# TMR replicas stay three cells each and every one lands in the chain.
yosys -q -p "
    read_verilog -sv -DZIRH_SIM_ENV ${ROOT}/src/zirh_tmr_lib.v;
    read_verilog -sv -DZIRH_SIM_ENV ${ROOT}/src/zirh_clkobs.v;
    synth -top zirh_clkobs -flatten;
    attrmap -modattr -remove keep_hierarchy;
    flatten;
    opt_clean;
    dfflibmap -liberty ${LIB};
    abc -liberty ${LIB};
    opt_clean;
    stat -liberty ${LIB};
    write_json ${BUILD}/clkobs_gates.json"

echo "[2/3] stitch the chain"
CHAIN="$(python3 "${ROOT}/scripts/dft_scan_stitch.py" \
    "${BUILD}/clkobs_gates.json" "${BUILD}/clkobs_scan.json" \
    | grep -oE '^CHAIN [0-9]+' | grep -oE '[0-9]+')"
if [ -z "${CHAIN}" ]; then
    echo "FAIL: stitcher produced no chain"
    exit 1
fi
echo "      chain length: ${CHAIN} scan cells"

yosys -q -p "
    read_json ${BUILD}/clkobs_scan.json;
    write_verilog -noattr ${BUILD}/clkobs_scan.v"

echo "[3/3] prove the stitched netlist by shifting"
# The PDK's stdcell models route their function through delayed_*
# wires that only the specify-block timing checks drive - constructs
# Icarus does not support, so every flop would read X. Derive a
# functional copy at run time: drop the specify blocks and the
# delayed_ indirection, keep the foundry's own UDP structure intact.
sed -e '/specify/,/endspecify/d' \
    -e '/^\s*wire\s\+delayed_/d' \
    -e 's/delayed_//g' \
    "${CELLS_V}/sg13g2_stdcell.v" > "${BUILD}/cells_func.v"

iverilog -g2012 \
    -s tb_scan_chain -Ptb_scan_chain.CHAIN="${CHAIN}" \
    -o "${BUILD}/scan.vvp" \
    "${ROOT}/test/tb_scan_chain.v" \
    "${BUILD}/clkobs_scan.v" \
    "${BUILD}/cells_func.v" \
    "${CELLS_V}/sg13g2_udp.v"
vvp "${BUILD}/scan.vvp" | tee "${BUILD}/scan.log"

grep -q "SCAN_CHAIN: PASS" "${BUILD}/scan.log"
echo "----------------------------------------------------"
echo "PASS: scan flow proven - RTL untouched, chain of ${CHAIN} on real cells"
