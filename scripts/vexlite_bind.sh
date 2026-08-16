#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - bind the shipping core's cache arrays to RM 2P macros
#
#   bash scripts/vexlite_bind.sh <out.v>
#
# yosys memory_libmap against pnr/vexlite/rm_macros.memlib maps the
# I-cache data (512x32) and tag (64x23, padded) arrays onto the PDK's
# TWO-PORT RM macros - write on side A with the per-bit mask, read on
# side B - through the techmap bridge in rm_macro_map.v. The register
# file (two read ports; no macro shape holds it) stays flops by
# selection. The bound netlist is proven by tb_vex against the PDK's
# ideal 2P behavioral cores before any P&R sees it.
# =============================================================================
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/vexlite_bound.v}"
mkdir -p "$(dirname "${OUT}")"
SV="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_sram/verilog"
yosys -q -p "
    read_verilog -lib -DFUNCTIONAL ${SV}/RM_IHPSG13_2P_512x32_c2_bm_bist.v ${SV}/RM_IHPSG13_2P_64x32_c2.v;
    read_verilog ${ROOT}/src/vex/VexRiscv_Lite.v;
    hierarchy -top VexRiscv; proc; opt -fast;
    memory -nomap;
    memory_libmap -lib ${ROOT}/pnr/vexlite/rm_macros.memlib InstructionCache;
    techmap -map ${ROOT}/pnr/vexlite/rm_macro_map.v;
    write_verilog -noattr ${OUT}"
N=$(grep -c "RM_IHPSG13_2P" "${OUT}")
echo "bound: ${N} RM 2P instances in ${OUT}"
test "${N}" -eq 2
