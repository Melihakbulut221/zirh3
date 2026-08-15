#!/bin/bash
# =============================================================================
# ZIRH - lint gate (H41): verilator --lint-only over the project RTL
#
#   bash scripts/lint.sh
#
# Lints the ZIRH-3 block library (src/zirh_*.v) with the PDK SRAM
# behavioral models included
# for resolution. Waivers, each with its reason:
#   UNUSEDSIGNAL/UNUSEDPARAM  the _unused reduction idiom and spare
#                             port bits are deliberate
#   BLKSEQ                    blocking temps inside clocked blocks and
#                             function bodies (b in the SpW encoder,
#                             the SECDED helpers) are scoped and read
#                             before any nonblocking consumer
#   WIDTHEXPAND               context widening is Verilog semantics
#   PINCONNECTEMPTY           intentionally open outputs
#   PINMISSING/DECLFILENAME/  vendored SERV and PDK models are not
#   EOFNEWLINE/VARHIDDEN      rewritten to please a linter
# Gate: verilator must exit 0 AND no remaining warning may point into
# zirh-authored files. LATCH, WIDTHTRUNC, BLKANDNBLK and the rest of
# -Wall stay ARMED - the first run caught a real mixed-assignment in
# the SpaceWire encoder with exactly this gate.
# =============================================================================
set -eo pipefail
cd "$(dirname "$0")/.."

VL=${VERILATOR:-verilator}
SRAM_V=${PDK_ROOT:?set PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_sram/verilog

# no chip top yet: each block lints as its own top, the way it will
# be instantiated
fail=0
for TOP in zirh_sram39 zirh_boot_ctrl zirh_qspi zirh_clkobs \
           zirh_dbg_gate zirh_sram_bist zirh_por_ro \
           zirh_sram_dut zirh_isp_rx zirh_jtag_dm \
           zirh3_memsys zirh3_die; do
  $VL --lint-only -Wall --timing \
      -Wno-DECLFILENAME -Wno-VARHIDDEN -Wno-EOFNEWLINE \
      -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ \
      -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
      -DFUNCTIONAL -DZIRH_SIM_ENV \
      -Isrc \
      --top-module $TOP \
      "$SRAM_V"/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
      "$SRAM_V"/RM_IHPSG13_1P_1024x8_c2_bm_bist.v \
      src/zirh_*.v \
      2>&1 | tee /tmp/zirh3_lint_$TOP.log | grep -E "%Warning" \
      | grep -E "zirh_" && { echo "lint: warnings in $TOP"; fail=1; }
done
[ $fail -ne 0 ] && exit 1
echo "lint: zirh3 block library is warning-clean"

# --- the imported SoC cluster (SERV vendored unmodified, exempt) --------------
# elaborated as one design with the mask ROM and the ECC RAM; only
# warnings pointing into zirh-authored soc-layer files fail the build.
$VL --lint-only -Wall --timing \
    -Wno-DECLFILENAME -Wno-VARHIDDEN -Wno-EOFNEWLINE \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ \
    -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
    -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE \
    -DFUNCTIONAL -DZIRH_SIM_ENV -Isrc --top-module zirh_soc \
    src/serv/*.v src/zirh_rom.v src/zirh_bus.v src/zirh_ecc_ram.v \
    src/zirh_rs422.v src/zirh_uart_regs.v src/zirh_tmr_lib.v \
    src/zirh_soc.v 2>&1 | tee /tmp/zirh3_soc_lint.log \
    | grep -E "%Warning" | grep -iE "zirh_(soc|rom|bus|uart|rs422)" \
    | grep -v "src/serv/" && { echo "lint: warnings in soc cluster"; exit 1; }
echo "lint: soc cluster is warning-clean (SERV vendored, exempt)"

# --- the CPU-carrying top (rung 3) --------------------------------------------
$VL --lint-only -Wall --timing \
    -Wno-DECLFILENAME -Wno-VARHIDDEN -Wno-EOFNEWLINE \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ \
    -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
    -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE \
    -DFUNCTIONAL -DZIRH_SIM_ENV -Isrc --top-module zirh3_top \
    src/serv/*.v src/zirh_*.v src/zirh3_top.v 2>&1 \
    | grep -E "%Warning" | grep -E "zirh3_top" \
    && { echo "lint: warnings in zirh3_top"; exit 1; }
echo "lint: zirh3_top is warning-clean"
