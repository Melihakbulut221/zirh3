#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - Cycle 23: raw netgen LVS (runs INSIDE the librelane container)
#
# The flow's own Netgen.LVS step dies in its harness, not its tool:
# netgen emits a stats JSON with raw backslash escapes and the step's
# json.loads chokes on it (the Cycle 15 r5n finding). Same recipe,
# no -json, and the report is parsed by the workflow instead: the
# extracted layout spice against the powered netlist plus the PDK's
# cell SPICE models, blackbox mode, librelane's own setup script.
#
#   signoff_lvs.sh <extracted.spice> <powered.pnl.v> <report-out>
# =============================================================================
set -euo pipefail

SPICE="${1:?extracted spice}"
PNL="${2:?powered netlist}"
OUT="${3:?report path}"

SETUP=$(python3 -c "import librelane, os; print(os.path.join(os.path.dirname(librelane.__file__), 'scripts', 'netgen', 'setup.tcl'))")
CELLS=/pdk/ihp-sg13g2/libs.ref/sg13g2_stdcell/spice/sg13g2_stdcell.spice

cat > /tmp/lvs_script.lvs <<EOF
set circuit1 [readnet spice ${SPICE}]
set circuit2 [readnet verilog /dev/null]
puts "Reading cell SPICE models '${CELLS}'..."
readnet spice ${CELLS} \$circuit2
puts "Reading powered netlist '${PNL}'..."
readnet verilog ${PNL} \$circuit2
lvs "\$circuit1 zirh_vex_wrap" "\$circuit2 zirh_vex_wrap" ${SETUP} ${OUT} -blackbox
EOF

netgen -batch source /tmp/lvs_script.lvs
