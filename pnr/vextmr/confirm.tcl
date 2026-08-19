# =============================================================================
# ZIRH-3 - Cycle 20: the self-healing signoff loop on the STITCHED layout
#
# Round 2 finished the flow with setup closed at every corner and hold
# 0.156 short at the fast corner - the exact failure shape the
# vexlitemac campaign taught us not to chase with estimate-side margin
# knobs. Cycle 18's instrument applies verbatim: route the exact
# layout, extract the truth with the flow's own pattern rules, and if
# the routed truth says hold is short, repair AGAINST that truth and
# route again. Green iff setup AND hold close at every corner.
# =============================================================================

set_thread_count 4

read_db /work/confirm_in/zirh_vex_wrap.odb

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

# the setup repair arm estimates rebuffering against wire RC and dies
# without it (RSZ-0089, round 4) - the hold arm never asked; the PDK's
# own defaults per its librelane config: signal Metal2, clock Metal5
set_wire_rc -signal -layer Metal2
set_wire_rc -clock  -layer Metal5

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
    write_spef /work/confirm_out/zirh_vex_wrap_confirm.spef
    read_spef /work/confirm_out/zirh_vex_wrap_confirm.spef
}

# the signoff loop, reshaped by round 3's lessons: (1) pass 1 judges
# the FLOW's own wires - they are valid and consistent, stripping them
# only traded a good layout for router noise; (2) the repair arm fixes
# WHATEVER the truth says is broken - round 3's loop repaired hold
# while setup drowned (-0.57) because Cycle 18's die had +5 ns of
# setup margin and this one does not; (3) margins sit above the
# observed from-scratch reroute noise (~0.3-0.4 ns between passes)
for {set i 1} {$i <= 4} {incr i} {
    if {$i == 1} {
        puts "=== CONFIRM PASS $i: judging the flow's own wires ==="
        define_process_corner -ext_model_index 0 X
        extract_parasitics -ext_model_file /pdk/ihp-sg13g2/libs.tech/librelane/openrcx/IHP_rcx_patterns.rules
        write_spef /work/confirm_out/zirh_vex_wrap_confirm.spef
        read_spef /work/confirm_out/zirh_vex_wrap_confirm.spef
    } else {
        puts "=== CONFIRM PASS $i: route + extract ==="
        route_extract
    }
    puts "=== CONFIRM PASS $i VERDICT ==="
    report_worst_slack -min
    report_worst_slack -max
    set min_ws [sta::worst_slack -min]
    set max_ws [sta::worst_slack -max]
    if {$min_ws >= 0 && $max_ws >= 0} { break }
    if {$i < 4} {
        puts "=== CONFIRM PASS $i: repairing against the ROUTED truth ==="
        remove_fillers
        if {$min_ws < 0} { repair_timing -hold -hold_margin 0.20 }
        if {$max_ws < 0} { repair_timing -setup -setup_margin 0.30 }
        detailed_placement
        filler_placement sg13g2_fill*
        check_placement
    }
}

# the repair arms must never touch the triples: count the flops
set nflops 0
foreach inst [[ord::get_db_block] getInsts] {
    if {[string match sg13g2_dfrbpq* [[$inst getMaster] getName]]} {
        incr nflops
    }
}
puts "FLOPS IN THE CONFIRMED LAYOUT: $nflops"

puts "=== CONFIRM VERDICT (routed + extracted, 3 corners) ==="
report_worst_slack -min
report_worst_slack -max

write_db  /work/confirm_out/zirh_vex_wrap_confirm.odb
write_def /work/confirm_out/zirh_vex_wrap_confirm.def
puts "=== CONFIRM DONE ==="
