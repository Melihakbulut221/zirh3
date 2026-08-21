#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - the FULL-DIE gate-level boot (Cycle 25)
#
# Cycle 19 proved the stitched CPU inside an RTL die; this proof puts
# the WHOLE die on gates: loader, bank arbiter, telemetry, watchdog,
# debug gate, POR - everything except the SRAM macros (behavioral, as
# every sim) and the CPU cluster, which links in as the STITCHED
# netlist from the gl ladder. The top is synthesized WITHOUT
# flattening, so u_soc.u_cpu keeps its path and the wound trio and
# the SEU rain run against the full gate die unchanged.
#
# Simulation parameters (BANK_PAGES=4 etc.) and the ROM hex are baked
# in with chparam - a gate netlist has no parameters left to override.
# por_ro's RO is its ZIRH_SIM_ENV divider model: synthesizable, no
# combinational loop, same behavior the RTL suite proves against.
#
#   [1/3] gates - synthesize zirh3_top to SG13G2 (macros + CPU black)
#   [2/3] boot  - the gate die + stitched CPU boot the ISP story
#   [3/3] wound - the wound trio + the SEU rain on the full gate die
#
#   PDK_ROOT=... bash scripts/gl_die.sh [gates|boot|wound|all]
#   (needs the gl ladder's bind/gates/stitch products; run
#    scripts/gl_boot.sh bind, gates, stitch first if absent)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CPU_BUILD="${ROOT}/test/sim_build/gl_boot"
BUILD="${ROOT}/test/sim_build/gl_die"
STAGE="${1:-all}"

: "${PDK_ROOT:?set PDK_ROOT to the ciel-managed PDK}"
LIB="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"
CELLS_V="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog"
SV="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_sram/verilog"

mkdir -p "${BUILD}"

case "${STAGE}" in
    gates|boot|wound|all) ;;
    *) echo "unknown stage '${STAGE}'"; exit 1;;
esac

run_stage() { case "${STAGE}" in "$1"|all) return 0;; *) return 1;; esac; }

if run_stage gates; then
    echo "[1/3] synthesizing the WHOLE die to SG13G2 gates"
    test -f "${CPU_BUILD}/vexwrap_tmr.v" || {
        echo "missing stitched CPU netlist - run gl_boot.sh bind/gates/stitch first"
        exit 1
    }
    # the PROVEN compile set - Makefile.top's list minus the CPU pair
    # (a src glob drags in include-only files that do not parse alone)
    RTL_FILES=""
    for f in zirh_tmr_lib zirh_tmr_ff32 zirh_rom zirh_bus zirh_ecc_ram \
             zirh_rs422 zirh_uart_regs zirh_soc zirh_boot_ctrl zirh_isp_rx \
             zirh_jtag_dm zirh_dbg_gate zirh_clkobs zirh_por_ro zirh_hk \
             zirh_tlm2 zirh_mbist zirh_gpio zirh_timer zirh_i2c zirh_spi zirh_uart1 zirh_bank64 zirh_sram_bist zirh_sram39; do
        RTL_FILES="${RTL_FILES} ${ROOT}/src/${f}.v"
    done
    RTL_FILES="${RTL_FILES} ${ROOT}/src/zirh3_top.v"
    cat > "${BUILD}/die.ys" <<EOF
read_verilog -lib -DFUNCTIONAL ${SV}/RM_IHPSG13_1P_1024x8_c2_bm_bist.v ${SV}/RM_IHPSG13_1P_4096x8_c3_bm_bist.v
read_verilog -lib ${ROOT}/src/zirh_vex_wrap.v
read_verilog -sv -DZIRH_SIM_ENV -I${ROOT}/src${RTL_FILES}
# chparam BEFORE hierarchy: once hierarchy resolves paramods it deletes
# the base modules, and a later param change would ask synth's own
# hierarchy pass to re-derive from modules that no longer exist
chparam -set ROM_HEX "${ROOT}/fw/rom.hex" -set RESET_DIV 20 -set POR_CYCLES 16 -set INTERVAL_LOG2 13 -set WD_LIMIT_LOG2 17 -set BANK_PAGES 4 -set BANK_WORDS 8192 zirh3_top
hierarchy -top zirh3_top
synth -top zirh3_top
dfflibmap -liberty ${LIB}
abc -liberty ${LIB}
opt_clean
stat -liberty ${LIB}
write_verilog -noattr ${BUILD}/zirh3_top_gates.v
EOF
    yosys -s "${BUILD}/die.ys" 2>&1 | tee "${BUILD}/die.log"

    # the netlist keeps its hierarchy (so the wound benches keep their
    # paths), which means the macro instantiation is written ONCE in
    # the slice module and multiplied by instantiation - a textual
    # count cannot see 20. Existence is checked here; the bank's
    # functional judge is the boot itself (a die without its bank
    # cannot commit an image, let alone run from it).
    N_1P=$(grep -c "RM_IHPSG13_1P_4096x8_c3_bm_bist" "${BUILD}/zirh3_top_gates.v" || true)
    echo "RM 1P macro references in the gate die: ${N_1P} (>= 1)"
    test "${N_1P}" -ge 1
    N_CPU=$(grep -c "zirh_vex_wrap u_cpu" "${BUILD}/zirh3_top_gates.v" || true)
    echo "CPU blackbox instances: ${N_CPU} (must be 1)"
    test "${N_CPU}" -eq 1
    echo "DIE_GATES: PASS - the die is gates, the CPU socket is open"

    sed -e '/specify/,/endspecify/d' \
        -e '/^\s*wire\s\+delayed_/d' \
        -e 's/delayed_//g' \
        "${CELLS_V}/sg13g2_stdcell.v" > "${BUILD}/cells_func.v"
fi

if run_stage boot; then
    echo "[2/3] the gate die + stitched CPU boot the ISP story"
    COCOTB_TEST_FILTER=test_isp_loads_and_the_program_speaks \
        make -C "${ROOT}/test" -B -f Makefile.gltop SIM_BUILD=sim_build/gltop
    echo "DIE_BOOT: PASS - the full die boots at gate level"
fi

if run_stage wound; then
    echo "[3/3] the wound trio + the SEU rain on the full gate die"
    N_TMR=$(grep -oE 'TMR [0-9]+ flops' "${CPU_BUILD}/stitch.log" | grep -oE '[0-9]+')
    GL_TMR_N="${N_TMR}" \
        make -C "${ROOT}/test" -B -f Makefile.gltop \
        COCOTB_TEST_MODULES=test_top_gl SIM_BUILD=sim_build/gltop_wound
    GL_TMR_N="${N_TMR}" GL_SEU_SEED="${GL_SEU_SEED:-1}" \
        make -C "${ROOT}/test" -B -f Makefile.gltop \
        COCOTB_TEST_MODULES=test_top_seu SIM_BUILD=sim_build/gltop_seu
    echo "DIE_WOUND: PASS - the vote holds on the full gate die, rail-dead and rained-on"
fi

echo "GL_DIE_PROOF: DONE (${STAGE})"
