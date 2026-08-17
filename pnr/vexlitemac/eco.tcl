# =============================================================================
# ZIRH-3 - the hold ECO (Cycle 16): repair_timing on the final ODB
#
# Runs inside the librelane image on the campaign's 0.15-baseline
# final artifact. Scenario is the hold-critical fast corner (stdcell
# fast 1.32V/-40C; the SRAM's fast deck is cut at -55C - the nearest
# the PDK ships, noted). Sequence: SPEF-accurate before-STA, hold
# repair with setup guarded, legalize, incremental global route,
# GRT-parasitic after-STA. The full detailed-route confirm follows
# once the numbers land.
# =============================================================================

read_db /work/eco_in/final/odb/zirh_vex_wrap.odb

read_liberty /pdk/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_fast_1p32V_m40C.lib
read_liberty /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_512x32_c2_bm_bist_fast_1p32V_m55C.lib
read_liberty /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_64x32_c2_fast_1p32V_m55C.lib

read_spef /work/eco_in/final/spef/nom/zirh_vex_wrap.nom.spef

create_clock -name clk -period 20 [get_ports clk]
set_propagated_clock [all_clocks]

puts "=== ECO BEFORE (SPEF, fast corner) ==="
report_worst_slack -min
report_worst_slack -max

# the final ODB arrives packed with filler cells - an ECO's first
# move is to reclaim their sites for the hold buffers
remove_fillers

repair_timing -hold -hold_margin 0.15

detailed_placement

global_route -congestion_iterations 30
estimate_parasitics -global_routing

filler_placement sg13g2_fill*
check_placement

puts "=== ECO MID (GRT estimate - advisory only) ==="
report_worst_slack -min
report_worst_slack -max

# the confirm loop, signoff grade: route the repair for real, extract
# real parasitics, and let SPEF-accurate STA speak the final word
detailed_route
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file /pdk/ihp-sg13g2/libs.tech/librelane/openrcx/ihp-sg13g2.nom.magic.rules
write_spef /work/eco_out/zirh_vex_wrap_eco.spef
read_spef /work/eco_out/zirh_vex_wrap_eco.spef

puts "=== ECO AFTER (routed + extracted SPEF, fast corner) ==="
report_worst_slack -min
report_worst_slack -max

write_db /work/eco_out/zirh_vex_wrap_eco.odb
write_def /work/eco_out/zirh_vex_wrap_eco.def
puts "=== ECO DONE ==="
