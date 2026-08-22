# =============================================================================
# ZIRH-3 - explicit PNR SDC for the macro-bound core (campaign round 5s)
#
# The zirh2 construction-SDC pattern, with this die's one addition:
# the 26 hold violations all end at the RM macros' DATA inputs (the
# STA reports name icache_data_m/icache_tags_m as endpoints), where
# the macro's internal clock latency shifts the capture edge and the
# resizer's generic hold repair never pads the path. set_min_delay on
# exactly those pins makes the repair SURGICAL: the resizer must pad
# flop-to-macro data paths and nothing else. Signoff STA keeps its
# own SDC - this file constrains construction, not the verdict.
# =============================================================================

create_clock -name clk -period 20 [get_ports clk]

set_input_delay  4 -clock clk [get_ports {rst_n timer_irq_i ext_irq_i[*] reset_vector_i[*] ibus_rdt_i[*] ibus_ack_i dbus_rdt_i[*] dbus_ack_i}]
set_output_delay 4 -clock clk [all_outputs]

set_max_fanout 16 [current_design]

# ROUND 5v POST-MORTEM: set_min_delay is not a repair driver - it
# REDEFINES the hold check itself, so the reported violations became
# the constraint's own unmet demand and the pads ate a real setup
# path. Removed; the resizer's own hold repair (with its buffer
# budget raised in the config) is the correct instrument.
