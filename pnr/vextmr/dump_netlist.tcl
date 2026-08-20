# =============================================================================
# ZIRH-3 - Cycle 21: the confirmed layout speaks for itself
#
# Read the CONFIRMED database (Cycle 20 round 6: hold and setup closed
# at every corner, 30 hold buffers and the setup repairs in place) and
# write the verilog netlist OF THAT LAYOUT - the one the boot proof
# will simulate. Physical-only cells (fillers, decaps, taps) carry no
# logic and are dropped from the writeout.
# =============================================================================

read_db /work/confirm_in/zirh_vex_wrap.odb
write_verilog -remove_cells {sg13g2_fill_1 sg13g2_fill_2 sg13g2_fill_4 sg13g2_fill_8 sg13g2_decap_4 sg13g2_decap_8 sg13g2_tap} /work/confirm_out/zirh_vex_wrap_pnr.v
puts "NETLIST DUMPED"
