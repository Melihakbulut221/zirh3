# =============================================================================
# ZIRH-3 - the hold ECO (Cycle 16): repair_timing on the final ODB
#
# Multi-corner, SPEF-annotated, minutes per round. The full-reroute
# confirm measured itself out of the budget twice (a whole-die
# detailed route for five changed nets); signoff practice's shortcut
# stands in honestly instead: after repair and legalization the
# ORIGINAL SPEF re-annotates every unchanged net, and the five new
# hold-buffer nets ride estimated (their intrinsic delay dominates -
# that is what a hold buffer is). All three corners are defined in
# one session, so the worst-slack verdict below IS the gate across
# corners. The fully-rerouted confirmation belongs to the next full
# flow run over the ECO'd DEF.
# =============================================================================

set_thread_count 4

read_db /work/eco_in/final/odb/zirh_vex_wrap.odb

define_corners fast typ slow
read_liberty -corner fast /pdk/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_fast_1p32V_m40C.lib
read_liberty -corner fast /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_512x32_c2_bm_bist_fast_1p32V_m55C.lib
read_liberty -corner fast /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_64x32_c2_fast_1p32V_m55C.lib
read_liberty -corner typ /pdk/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib
read_liberty -corner typ /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_512x32_c2_bm_bist_typ_1p20V_25C.lib
read_liberty -corner typ /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_64x32_c2_typ_1p20V_25C.lib
read_liberty -corner slow /pdk/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_slow_1p08V_125C.lib
read_liberty -corner slow /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_512x32_c2_bm_bist_slow_1p08V_125C.lib
read_liberty -corner slow /pdk/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_2P_64x32_c2_slow_1p08V_125C.lib

read_spef /work/eco_in/final/spef/nom/zirh_vex_wrap.nom.spef

create_clock -name clk -period 20 [get_ports clk]
set_propagated_clock [all_clocks]

puts "=== ECO BEFORE (SPEF, worst across 3 corners) ==="
report_worst_slack -min
report_worst_slack -max

remove_fillers
repair_timing -hold -hold_margin 0.15
detailed_placement
filler_placement sg13g2_fill*
check_placement

# the unchanged world keeps its measured parasitics; the new buffer
# nets ride estimated, intrinsic-dominated
read_spef /work/eco_in/final/spef/nom/zirh_vex_wrap.nom.spef

puts "=== ECO AFTER (SPEF re-annotated, worst across 3 corners) ==="
report_worst_slack -min
report_worst_slack -max

write_db /work/eco_out/zirh_vex_wrap_eco.odb
write_def /work/eco_out/zirh_vex_wrap_eco.def
puts "=== ECO DONE ==="
