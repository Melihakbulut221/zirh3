#!/usr/bin/env bash
# =============================================================================
# ZIRH-3 - the clock campaign's synthesis leg (Cycle 14 rung 4)
#
#   bash scripts/clk_campaign.sh
#
# Critical-path measurement at the synthesis level for the three
# timing questions the parity ladder asks: the bare core, the
# triple-core candidate, and the single-voter delta pilot B adds to
# every flop path. Memories stay as $mem so abc treats them as
# macro boundaries - the first run of this campaign measured a 783 ns
# "critical path" that was nothing but the instruction-cache array
# rendered as a mux forest, an artifact the real die never builds.
#
# MEASURED (typ 1.20V 25C, gate delays only, no wires):
#   zirh_vex_wrap  21702 ps  (~46 MHz)
#   zirh_vex_tmr   21970 ps  (+1.2% - bus voters are noise)
#   single voter      81 ps  (+0.4% per flop path - pilot B is cheap)
# The limiter is the core's own path, not the protection. 50 MHz
# needs retiming/P&R effort or a 45 MHz target; either way the
# protection choice is NOT timing-bound.
# =============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${PDK_ROOT}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"
ABC_SCRIPT="+strash;dch;map,-D,20000;topo;stime"

echo "ZIRH-3 clock campaign (synthesis leg, typ corner)"
echo "-------------------------------------------------"

for TOP in zirh_vex_wrap zirh_vex_tmr; do
    echo "== ${TOP}"
    yosys -p "
        read_verilog ${ROOT}/src/vex/VexRiscv_Lite.v;
        read_verilog ${ROOT}/src/zirh_tmr_lib.v;
        read_verilog ${ROOT}/src/zirh_vex_wrap.v;
        read_verilog ${ROOT}/src/zirh_vex_tmr.v;
        hierarchy -top ${TOP};
        synth -top ${TOP} -flatten -run begin:fine;
        opt -full; techmap; opt -full;
        dfflibmap -liberty ${LIB};
        abc -liberty ${LIB} -script \"${ABC_SCRIPT}\"" 2>&1 \
        | grep -aE "ABC:.*Delay" | tail -1
done

echo "== single voter (pilot B per-flop delta)"
TMP="$(mktemp -d)"
cat > "${TMP}/voter1.v" <<'EOF'
module voter1(input wire a, input wire b, input wire c, output wire y);
  assign y = (a & b) | (b & c) | (a & c);
endmodule
EOF
yosys -p "
    read_verilog ${TMP}/voter1.v;
    synth -top voter1 -flatten;
    abc -liberty ${LIB} -script \"+strash;dch;map;topo;stime\"" 2>&1 \
    | grep -aE "ABC:.*Delay" | tail -1
rm -rf "${TMP}"

echo "-------------------------------------------------"
echo "Done. Compare against the 20000 ps (50 MHz) budget."
