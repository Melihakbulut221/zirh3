#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - Cycle 21: the POST-P&R netlist boots (full circle)
#
# Cycle 19 proved the stitched netlist we HANDED to the flow; Cycle 20
# proved the flow closes timing on it without killing the triples.
# This script closes the circle: the netlist that comes OUT of the
# layout - clock tree, hold buffers, setup repairs, tie cells and all
# - must boot the ISP story and survive the wound trio, same benches,
# same discipline (test/test_top_gl.py).
#
#   PDK_ROOT=... bash scripts/gl_pnr_boot.sh <post-pnr-netlist.v>
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/test/sim_build/gl_pnr"
NETLIST="${1:?path to the post-P&R netlist}"

: "${PDK_ROOT:?set PDK_ROOT to the ciel-managed PDK}"
CELLS_V="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog"
SV="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_sram/verilog"

mkdir -p "${BUILD}"

# the rails must be present by name, or the wound bench has nothing to
# reach - count them before burning simulation time
for R in tmrA tmrB tmrC; do
    N=$(grep -cE "wire ${R}_[0-9]+;" "${NETLIST}" || true)
    echo "${R} rails in the netlist: ${N}"
    test "${N}" -eq 2138
done

sed -e '/specify/,/endspecify/d' \
    -e '/^\s*wire\s\+delayed_/d' \
    -e 's/delayed_//g' \
    "${CELLS_V}/sg13g2_stdcell.v" > "${BUILD}/cells_func.v"

GL_SOURCES="${NETLIST} ${BUILD}/cells_func.v ${CELLS_V}/sg13g2_udp.v ${SV}/RM_IHPSG13_2P_512x32_c2_bm_bist.v ${SV}/RM_IHPSG13_2P_64x32_c2.v ${SV}/RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v ${SV}/RM_IHPSG13_2P_core_behavioral_ideal.v"

GL_TMR_N=2138 \
    make -C "${ROOT}/test" -B -f Makefile.top \
    CPU_SOURCES="${GL_SOURCES}" COCOTB_TEST_MODULES=test_top_gl \
    SIM_BUILD=sim_build/gl_pnr

echo "GL_PNR_BOOT: PASS - the layout's own netlist boots, wounded and healed"
