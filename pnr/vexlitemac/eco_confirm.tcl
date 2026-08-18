# =============================================================================
# ZIRH-3 - Cycle 18: the full-flow confirm of the ECO'd layout
#
# The deferred theorem, proven properly: the EXACT post-ECO database
# (14 hold buffers placed, rows resealed) gets real global+detailed
# routing, real OpenRCX extraction, and a three-corner SPEF STA. The
# gate is the verdict step in the workflow: green iff setup AND hold
# close at every corner on this layout.
# =============================================================================

set_thread_count 4

read_db /work/eco_in/zirh_vex_wrap_eco.odb

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

create_clock -name clk -period 20 [get_ports clk]
set_propagated_clock [all_clocks]

puts "=== CONFIRM: routing the ECO'd layout for real ==="
global_route -congestion_iterations 30
detailed_route

puts "=== CONFIRM: extracting real parasitics ==="
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file /pdk/ihp-sg13g2/libs.tech/librelane/openrcx/ihp-sg13g2.nom.magic.rules
write_spef /work/eco_out/zirh_vex_wrap_confirm.spef
read_spef /work/eco_out/zirh_vex_wrap_confirm.spef

puts "=== CONFIRM VERDICT (routed + extracted, 3 corners) ==="
report_worst_slack -min
report_worst_slack -max

write_db  /work/eco_out/zirh_vex_wrap_confirm.odb
write_def /work/eco_out/zirh_vex_wrap_confirm.def
puts "=== CONFIRM DONE ==="
