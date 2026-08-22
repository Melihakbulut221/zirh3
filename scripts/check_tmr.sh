#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - synthesis integrity check for TMR structures
#
#   bash scripts/check_tmr.sh
#
# The same proof zirh2's flow runs on every commit, scoped to the
# blocks this repository carries: synthesize each one the way the
# real flow does (-flatten, opt) and count the replica instances and
# flip-flops that survive. Numbers below are MEASURED on the
# imported, verified blocks at import time - update them together
# with the RTL and say why in the commit.
# =============================================================================
set -u

SRC="$(cd "$(dirname "$0")/../src" && pwd)"
failures=0

run_check() {
    local label="$1" top="$2" exp_rep="$3" exp_ff="$4" rep_mod="$5"
    shift 5
    local files=("$@")

    local read_cmds=""
    for f in "${files[@]}"; do
        read_cmds+="read_verilog -sv -DZIRH_SIM_ENV ${SRC}/${f}; "
    done

    local script="${read_cmds}
        ${EXTRA_CMDS:-}
        hierarchy -check -top ${top};
        synth -top ${top} -flatten -run begin:fine;
        opt -full;
        memory_map;
        techmap;
        opt -full;
        select -count t:*${rep_mod}*;
        stat -top ${top};"

    local out
    if ! out="$(yosys -p "${script}" 2>&1)"; then
        echo "  FAIL  ${label}: yosys returned an error"
        echo "${out}" | tail -5 | sed 's/^/        /'
        failures=$((failures + 1))
        return
    fi

    # Replica instances: "select -count" prints "<N> objects.".
    # It counts cells per module DEFINITION, which is what we want here -
    # each replica is a separate cell in the parent module.
    local got_rep
    got_rep="$(echo "${out}" | grep -oE '^[0-9]+ objects\.$' | grep -oE '^[0-9]+' | head -1)"

    # Flip-flops: taken from the LAST section of `stat`. When the design still
    # has hierarchy that is the "design hierarchy" summary, which multiplies
    # each submodule's cells by its instance count - a plain `select -count`
    # would undercount, since it sees each module definition only once no
    # matter how many times it is instantiated. When everything collapsed into
    # a single module there is no hierarchy summary, and the last section is
    # the top module itself; summing there still reports the real number
    # instead of a misleading zero.
    local got_ff
    got_ff="$(echo "${out}" | awk '/^=== /{s=0} /DFF/{s+=$NF} END{print s+0}')"

    if [ -z "${got_rep}" ]; then
        echo "  FAIL  ${label}: could not parse replica count from yosys output"
        failures=$((failures + 1))
        return
    fi

    local ok=1

    if [ "${got_rep}" -ne "${exp_rep}" ]; then
        echo "  FAIL  ${label}: ${rep_mod} instances = ${got_rep}, expected ${exp_rep}"
        if [ "${got_rep}" -lt "${exp_rep}" ]; then
            echo "        replicas were MERGED - the TMR in ${top} is gone"
        fi
        ok=0
    fi

    if [ "${got_ff}" -ne "${exp_ff}" ]; then
        echo "  FAIL  ${label}: flip-flop count = ${got_ff}, expected ${exp_ff}"
        ok=0
    fi

    if [ "${ok}" -eq 1 ]; then
        echo "  ok    ${label}: ${got_rep}x ${rep_mod}, ${got_ff} FFs"
    else
        failures=$((failures + 1))
    fi
}

echo "ZIRH-3 synthesis integrity check"
echo "--------------------------------"

EXTRA_CMDS=""
run_check "zirh_tmr_reg  (TMR register replicas)" \
    zirh_tmr_reg 3 25 zirh_tmr_ff \
    zirh_tmr_lib.v

run_check "zirh_boot_ctrl (loader, PROTECT=1)" \
    zirh_boot_ctrl 21 524 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_boot_ctrl.v

run_check "zirh_qspi     (QSPI-MRAM controller)" \
    zirh_qspi 18 221 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_qspi.v

run_check "zirh_clkobs   (clock-loss observer)" \
    zirh_clkobs 12 48 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_clkobs.v

run_check "zirh_dbg_gate (debug isolation)" \
    zirh_dbg_gate 3 7 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_dbg_gate.v

EXTRA_CMDS="read_verilog $(cd "$(dirname "$0")" && pwd)/sram_macro_stub.v;"
run_check "zirh_sram39   (sliced SECDED + scrubber)" \
    zirh_sram39 21 366 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_sram_bist.v zirh_sram39.v
EXTRA_CMDS=""

run_check "zirh_mbist    (MBIST doorway + page reg)" \
    zirh_mbist 6 27 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_mbist.v

run_check "zirh_gpio     (56-pin GPIO, TMR out/dir)" \
    zirh_gpio 6 453 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_gpio.v

run_check "zirh_timer    (24-timer bank, all-TMR)" \
    zirh_timer 12 9938 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_timer.v

run_check "zirh_i2c      (I2C master + slave chair, all-TMR)" \
    zirh_i2c 27 1208 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_fifo.v zirh_i2c.v

run_check "zirh_spi      (SPI master + queues, all-TMR)" \
    zirh_spi 15 1902 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_fifo.v zirh_spi.v

run_check "zirh_fifo     (TMR queue primitive)" \
    zirh_fifo 6 432 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_fifo.v

run_check "zirh_uart1    (payload UART + queues, all-TMR)" \
    zirh_uart1 15 1137 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_fifo.v zirh_uart1.v

run_check "zirh_irq      (interrupt fabric, TMR mask)" \
    zirh_irq 3 98 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_irq.v

# The POR/RO source carries no TMR by design (like the ECC RAM's SECDED
# path): triplicating a power-on counter is not the intent - it fails
# safe by holding reset. 17 plain flops MEASURED; the check guards that
# no replica sneaks in and the count stays put.
run_check "zirh_por_ro   (POR + RO clock, no TMR by design)" \
    zirh_por_ro 0 17 zirh_tmr_ff \
    zirh_por_ro.v

run_check "zirh_jtag_dm  (JTAG DTM + DM + boundary scan)" \
    zirh_jtag_dm 9 331 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_jtag_dm.v

EXTRA_CMDS="read_verilog $(cd "$(dirname "$0")" && pwd)/sram_macro_stub.v;"
run_check "zirh_sram_dut  (A6: 5 bare macros + BIST engine)" \
    zirh_sram_dut 18 158 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_sram_bist.v zirh_sram39.v zirh_sram_dut.v
EXTRA_CMDS=""

EXTRA_CMDS="read_verilog $(cd "$(dirname "$0")" && pwd)/sram_macro_stub.v;"
# Integration count is 48 replica-FFs / 959 FFs MEASURED - lower than
# the 72 the five blocks carry standalone because this skeleton ties
# off many inputs (signon, wd_fail, the debug SBA, BIST), and a
# register with a constant input constant-folds to a constant, which
# is NOT a replica merge. The authoritative merge guard is the
# per-block checks above (18/21/12/3/18, each proven intact); this
# entry is a regression tripwire on the integration as wired, and its
# number will move legitimately as tie-offs change with the SoC import.
run_check "zirh3_memsys  (integration: loader+bank+qspi+clkobs+dbg)" \
    zirh3_memsys 51 1151 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_sram_bist.v zirh_sram39.v zirh_boot_ctrl.v \
    zirh_qspi.v zirh_clkobs.v zirh_dbg_gate.v zirh3_memsys.v
EXTRA_CMDS=""

EXTRA_CMDS="read_verilog $(cd "$(dirname "$0")" && pwd)/sram_macro_stub.v;"
run_check "zirh3_die     (die: por_ro + isp_rx + jtag + memsys)" \
    zirh3_die 51 1525 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_sram_bist.v zirh_sram39.v zirh_boot_ctrl.v \
    zirh_qspi.v zirh_clkobs.v zirh_dbg_gate.v zirh_por_ro.v \
    zirh_isp_rx.v zirh_jtag_dm.v zirh3_memsys.v zirh3_die.v
EXTRA_CMDS=""

EXTRA_CMDS="read_verilog $(cd "$(dirname "$0")" && pwd)/sram_macro_stub.v;"
# Cycle 14: the VexRiscv_Lite core's instruction-cache ARRAY dominates
# this count - memory_map renders it as ~17.7k flops here, exactly as
# it renders every behavioral memory; at hardening the array binds to
# an SRAM macro like the bank's five slices do. The number is a
# tripwire, not a floorplan: what it guards is that the 70 replicas
# and the core's real state survive the optimizer unmerged.
run_check "zirh3_top     (full compute die + DFT)" \
    zirh3_top 85 53397 zirh_tmr_ff \
    zirh_tmr_lib.v vex/VexRiscv_Lite.v zirh_vex_wrap.v \
    zirh_rom.v zirh_bus.v zirh_ecc_ram.v zirh_rs422.v zirh_uart_regs.v \
    zirh_soc.v zirh_boot_ctrl.v zirh_isp_rx.v zirh_jtag_dm.v \
    zirh_dbg_gate.v zirh_clkobs.v zirh_por_ro.v zirh_sram_bist.v \
    zirh_sram39.v zirh_tmr_ff32.v zirh_hk.v zirh_tlm2.v zirh_mbist.v \
    zirh_qspi.v zirh_gpio.v zirh_timer.v zirh_i2c.v zirh_spi.v zirh_fifo.v zirh_uart1.v zirh_irq.v zirh_bank64.v zirh3_top.v
EXTRA_CMDS=""

echo "--------------------------------"
if [ "${failures}" -gt 0 ]; then
    echo "FAIL: ${failures} check(s) failed"
    exit 1
fi
echo "PASS: all hardening structures survived synthesis"
