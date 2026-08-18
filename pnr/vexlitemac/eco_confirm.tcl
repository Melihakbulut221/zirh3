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

proc strip_wires {} {
    set block [ord::get_db_block]
    foreach net [$block getNets] {
        set w [$net getWire]
        if {$w != "NULL"} { odb::dbWire_destroy $w }
    }
}

proc route_extract {} {
    strip_wires
    global_route -congestion_iterations 30
    detailed_route -droute_end_iter 40
    define_process_corner -ext_model_index 0 X
    extract_parasitics -ext_model_file /pdk/ihp-sg13g2/libs.tech/librelane/openrcx/IHP_rcx_patterns.rules
    write_spef /work/eco_out/zirh_vex_wrap_confirm.spef
    read_spef /work/eco_out/zirh_vex_wrap_confirm.spef
}

# the signoff loop: route the exact layout, extract the truth, and if
# the routed truth says the hold repair undershot, repair AGAINST that
# truth and route again - at most three passes, each verdict printed
for {set i 1} {$i <= 3} {incr i} {
    puts "=== CONFIRM PASS $i: route + extract ==="
    route_extract
    puts "=== CONFIRM PASS $i VERDICT ==="
    report_worst_slack -min
    report_worst_slack -max
    set min_ws [sta::worst_slack -min]
    set max_ws [sta::worst_slack -max]
    if {$min_ws >= 0 && $max_ws >= 0} { break }
    if {$i < 3} {
        puts "=== CONFIRM PASS $i: repairing against the ROUTED truth ==="
        remove_fillers
        repair_timing -hold -hold_margin 0.10
        detailed_placement
        filler_placement sg13g2_fill*
        check_placement
    }
}

puts "=== CONFIRM VERDICT (routed + extracted, 3 corners) ==="
report_worst_slack -min
report_worst_slack -max

write_db  /work/eco_out/zirh_vex_wrap_confirm.odb
write_def /work/eco_out/zirh_vex_wrap_confirm.def
puts "=== CONFIRM DONE ==="
