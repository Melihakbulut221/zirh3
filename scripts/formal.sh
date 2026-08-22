#!/bin/bash
# =============================================================================
# ZIRH-2 - formal verification of the escape-window theorem
#
#   bash scripts/formal.sh [N ...]     default: 4 8 32
#
# For each ring width N:
#   1. containment - BMC (depth 24) then k-induction: under any upset
#      stream confined to one replica per cycle, the voted output equals
#      the golden ring in every bit of every cycle. UNSAT = theorem.
#   2. witness - a cover trace where one same-bit two-replica upset
#      escapes to the ring output; the VCD lands in formal/out/ and is
#      the mechanism drawn by the solver (GTKWave-ready).
#
# Tools: yosys (read_verilog -sv -formal, write_smt2), yosys-smtbmc, z3.
# =============================================================================

set -e
cd "$(dirname "$0")/.."
mkdir -p formal/out

NS=${@:-"4 8 32"}
YOSYS=${YOSYS:-yosys}
SMTBMC=${SMTBMC:-yosys-smtbmc}

# Per-proof wall-clock cap: on a slow runner a single solver call must
# name itself rather than silently eating the whole CI budget. Prints
# elapsed seconds per proof so the log shows exactly what is slow.
# The default 300s is tuned for the CI gate (N=4); the deep N=32 BMC
# needs more room - SMT_CAP overrides it (formal-deep runs with 3600).
smt() {
  local label="$1"; shift
  local t0 rc
  t0=$SECONDS
  timeout "${SMT_CAP:-300}" "$@"; rc=$?
  echo "    [$label] $((SECONDS - t0))s (rc=$rc)"
  if [ $rc -ne 0 ]; then echo "FORMAL FAIL: $label (rc=$rc)"; exit 1; fi
}

# --- the instrument test, before any theorem ------------------------------
# A proof is only as honest as the tool that checked it. This stage
# hands the solver a claim that is FALSE by construction and demands to
# be refuted; a toolchain that drops assertions (a yosys emitting
# $check cells against a front-end that only queries $assert) reports
# PASSED over an empty proof, and every stage below would inherit that
# silence. Measured, not assumed: this exact failure produced four
# green "theorems" on a 0.67 toolchain before it was caught.
echo "=== instrument: the solver must refute a false claim ==="
$YOSYS -q -p "
  read_verilog -sv -formal formal/f_selftest.sv
  prep -top f_selftest
  write_smt2 formal/out/selftest.smt2"
if timeout "${SMT_CAP:-300}" $SMTBMC -s z3 --presat -t 8 \
       formal/out/selftest.smt2 > formal/out/selftest.log 2>&1; then
    echo "FORMAL FAIL: the toolchain ACCEPTED a false claim - assertions are"
    echo "             being dropped; every theorem below would be vacuous."
    echo "             (yosys $($YOSYS -V | head -1))"
    exit 1
fi
echo "    the instrument bites: assertions reach the solver"

for N in $NS; do
  echo "=== N=$N: containment (BMC + induction) ==="
  $YOSYS -q -p "
    read_verilog -sv -formal -DFORMAL src/zirh_tmr_lib.v formal/f_ring.sv
    chparam -set N $N f_ring
    prep -top f_ring
    write_smt2 formal/out/ring_n$N.smt2"
  # RING_T bounds the k-induction depth. The default 24 is the CI
  # gate's; the induction actually closes at k=22 (measured, and in
  # ONE second even at N=32), so the deep run uses RING_T=22 - the
  # N=32 BMC's per-step cost explodes past step 22 (step 22 alone
  # ~43 min locally) while adding nothing the induction needs.
  smt "ring N=$N BMC" $SMTBMC -s z3 --presat -t ${RING_T:-24} formal/out/ring_n$N.smt2
  smt "ring N=$N induction" $SMTBMC -s z3 --presat -i -t ${RING_T:-24} formal/out/ring_n$N.smt2
  echo "    PROVEN at N=$N (BMC clean, induction holds)"

  echo "=== N=$N: escape witness (cover) ==="
  $YOSYS -q -p "
    read_verilog -sv -formal -DFORMAL -DF_PAIR src/zirh_tmr_lib.v formal/f_ring.sv
    chparam -set N $N f_ring
    prep -top f_ring
    write_smt2 formal/out/pair_n$N.smt2"
  smt "ring N=$N witness" $SMTBMC -s z3 --presat -c -t $((N + 6)) \
      --dump-vcd formal/out/escape_n$N.vcd formal/out/pair_n$N.smt2
  echo "    WITNESS at N=$N: formal/out/escape_n$N.vcd"
done

echo "=== ECC RAM: SECDED contract (BMC, exhaustive over words/faults) ==="
$YOSYS -q -p "
  verilog_defaults -add -Isrc
  read_verilog -sv -formal -DFORMAL src/zirh_tmr_lib.v src/zirh_ecc_ram.v formal/f_ecc.sv
  prep -top f_ecc
  write_smt2 formal/out/ecc.smt2"
smt "ecc" $SMTBMC -s z3 --presat -t 12 formal/out/ecc.smt2
echo "    PROVEN: roundtrip, 1-bit correction (all 39 positions),"
echo "            2-bit detection, corrected merge on partial writes"

echo "=== address-in-ECC mask: wrong-row is always uncorrectable ==="
$YOSYS -q -p "
  verilog_defaults -add -Isrc
  read_verilog -sv -formal -DFORMAL src/zirh_tmr_lib.v formal/f_amask.sv
  prep -top f_amask
  write_smt2 formal/out/amask.smt2"
smt "amask" $SMTBMC -s z3 --presat -t 4 formal/out/amask.smt2
echo "    PROVEN: matching fold decodes clean and exact; any fold"
echo "            difference - every single-bit address flip - lands"
echo "            UNCORRECTABLE, never clean, never miscorrected"

echo "=== debug gate: the lock is an absorbing trapdoor (F27) ==="
$YOSYS -q -p "
  read_verilog -sv -formal src/zirh_tmr_lib.v src/zirh_dbg_gate.v formal/f_dbg.sv
  prep -top f_dbg
  write_smt2 formal/out/dbg.smt2"
smt "dbg BMC" $SMTBMC -s z3 --presat -t 12 formal/out/dbg.smt2
smt "dbg induction" $SMTBMC -s z3 --presat -i -t 12 formal/out/dbg.smt2
$YOSYS -q -p "
  read_verilog -sv -formal -DF_COVER src/zirh_tmr_lib.v src/zirh_dbg_gate.v formal/f_dbg.sv
  prep -top f_dbg
  write_smt2 formal/out/dbg_cover.smt2"
smt "dbg cover" $SMTBMC -s z3 --presat -c -t 6 formal/out/dbg_cover.smt2
echo "    PROVEN: locked is inert and absorbing; the bench path exists"

echo "=== boot controller: the trust anchor\'s rulings (Cycle 39) ==="
$YOSYS -q -p "
  read_verilog -sv -formal src/zirh_tmr_lib.v src/zirh_boot_ctrl.v formal/f_boot.sv
  prep -top f_boot
  write_smt2 formal/out/boot.smt2"
# the loader carries eight invariants; a build that lost some of them
# would still say PASSED, so the count is part of the gate
BOOT_A=$($YOSYS -p "read_verilog -sv -formal src/zirh_tmr_lib.v src/zirh_boot_ctrl.v formal/f_boot.sv; prep -top f_boot; stat" 2>/dev/null \
         | grep -F '$assert' | awk '{s += $2} END {print s+0}')
if [ "${BOOT_A:-0}" -lt 9 ]; then
    echo "FORMAL FAIL: boot harness carries $BOOT_A assertions, expected 9"
    exit 1
fi
echo "    $BOOT_A assertions in the harness"
smt "boot BMC"       $SMTBMC -s z3 --presat -t 24 formal/out/boot.smt2
smt "boot induction" $SMTBMC -s z3 --presat -i -t 24 formal/out/boot.smt2
$YOSYS -q -p "
  read_verilog -sv -formal -DF_COVER src/zirh_tmr_lib.v src/zirh_boot_ctrl.v formal/f_boot.sv
  prep -top f_boot
  write_smt2 formal/out/boot_cover.smt2"
# anti-vacuity: safety theorems about a loader that can never rule are
# free. Both verdicts must be REACHABLE in the same free-input machine.
smt "boot verdicts reachable" $SMTBMC -s z3 --presat -c -t 40 \
    --dump-vcd formal/out/boot_rule.vcd formal/out/boot_cover.smt2
echo "    PROVEN: a bank turns bootable only out of VERIFY; GOLDEN is"
echo "            absorbing; at flight straps a ruling is final - deaf,"
echo "            bus-silent and unable to re-enter the load path"

echo "formal: instrument checked; rings, ECC, address mask, debug lock and"
echo "        the boot controller proven, witnesses dumped"
