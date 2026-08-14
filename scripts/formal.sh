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

for N in $NS; do
  echo "=== N=$N: containment (BMC + induction) ==="
  $YOSYS -q -p "
    read_verilog -sv -formal -DFORMAL src/zirh_tmr_lib.v formal/f_ring.sv
    chparam -set N $N f_ring
    prep -top f_ring
    write_smt2 formal/out/ring_n$N.smt2"
  $SMTBMC -s z3 --presat -t 24 formal/out/ring_n$N.smt2
  $SMTBMC -s z3 --presat -i -t 24 formal/out/ring_n$N.smt2
  echo "    PROVEN at N=$N (BMC clean, induction holds)"

  echo "=== N=$N: escape witness (cover) ==="
  $YOSYS -q -p "
    read_verilog -sv -formal -DFORMAL -DF_PAIR src/zirh_tmr_lib.v formal/f_ring.sv
    chparam -set N $N f_ring
    prep -top f_ring
    write_smt2 formal/out/pair_n$N.smt2"
  $SMTBMC -s z3 --presat -c -t $((N + 6)) \
      --dump-vcd formal/out/escape_n$N.vcd formal/out/pair_n$N.smt2
  echo "    WITNESS at N=$N: formal/out/escape_n$N.vcd"
done

echo "=== ECC RAM: SECDED contract (BMC, exhaustive over words/faults) ==="
$YOSYS -q -p "
  verilog_defaults -add -Isrc
  read_verilog -sv -formal -DFORMAL src/zirh_tmr_lib.v src/zirh_ecc_ram.v formal/f_ecc.sv
  prep -top f_ecc
  write_smt2 formal/out/ecc.smt2"
$SMTBMC -s z3 --presat -t 12 formal/out/ecc.smt2
echo "    PROVEN: roundtrip, 1-bit correction (all 39 positions),"
echo "            2-bit detection, corrected merge on partial writes"

echo "=== address-in-ECC mask: wrong-row is always uncorrectable ==="
$YOSYS -q -p "
  verilog_defaults -add -Isrc
  read_verilog -sv -formal -DFORMAL src/zirh_tmr_lib.v formal/f_amask.sv
  prep -top f_amask
  write_smt2 formal/out/amask.smt2"
$SMTBMC -s z3 --presat -t 4 formal/out/amask.smt2
echo "    PROVEN: matching fold decodes clean and exact; any fold"
echo "            difference - every single-bit address flip - lands"
echo "            UNCORRECTABLE, never clean, never miscorrected"

echo "=== debug gate: the lock is an absorbing trapdoor (F27) ==="
$YOSYS -q -p "
  read_verilog -sv -formal src/zirh_tmr_lib.v src/zirh_dbg_gate.v formal/f_dbg.sv
  prep -top f_dbg
  write_smt2 formal/out/dbg.smt2"
$SMTBMC -s z3 --presat -t 12 formal/out/dbg.smt2
$SMTBMC -s z3 --presat -i -t 12 formal/out/dbg.smt2
$YOSYS -q -p "
  read_verilog -sv -formal -DF_COVER src/zirh_tmr_lib.v src/zirh_dbg_gate.v formal/f_dbg.sv
  prep -top f_dbg
  write_smt2 formal/out/dbg_cover.smt2"
$SMTBMC -s z3 --presat -c -t 6 formal/out/dbg_cover.smt2
echo "    PROVEN: locked is inert and absorbing; the bench path exists"

echo "formal: rings, ECC, address mask and debug lock proven, witnesses dumped"
