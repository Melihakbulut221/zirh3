// =============================================================================
// ZIRH-3 - triple-core lockstep candidate (Cycle 14 rung 3, pilot A)
// src/zirh_vex_tmr.v
//
// Three identical cores in lockstep behind ONE voted bus face: inputs
// fan out to all three, every outbound signal is majority-voted, and
// any disagreement raises the sticky divergence flag. A corrupted
// core diverges silently behind the voters - the bus, the memory and
// the mission never see it - but it does NOT self-heal: unlike the
// flop-level voted-feedback register, a diverged core stays diverged
// until the next reset. That is this candidate's honest trade: the
// simplest possible integration (the core is a black box, vendored
// and untouched) against a repair story that leans on the fabric this
// die already has - the divergence flag feeds err_o, and recovery is
// the watchdog/reset ladder that every other fault already uses.
//
// The interface is bit-identical to zirh_vex_wrap plus err_o, so the
// soc can host either candidate with a one-line change.
// =============================================================================

`default_nettype none

module zirh_vex_tmr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        timer_irq_i,
    input  wire [31:0] ext_irq_i,
    input  wire [31:0] reset_vector_i,

    output wire [31:0] ibus_adr_o,
    output wire        ibus_cyc_o,
    input  wire [31:0] ibus_rdt_i,
    input  wire        ibus_ack_i,

    output wire [31:0] dbus_adr_o,
    output wire [31:0] dbus_dat_o,
    output wire [3:0]  dbus_sel_o,
    output wire        dbus_we_o,
    output wire        dbus_cyc_o,
    input  wire [31:0] dbus_rdt_i,
    input  wire        dbus_ack_i,

    output reg         err_o          // sticky: a core has diverged
);

    wire [31:0] ia_a, ia_b, ia_c, da_a, da_b, da_c, dd_a, dd_b, dd_c;
    wire [3:0]  ds_a, ds_b, ds_c;
    wire        ic_a, ic_b, ic_c, dc_a, dc_b, dc_c, dw_a, dw_b, dw_c;

    zirh_vex_wrap u_a (
        .clk(clk), .rst_n(rst_n), .timer_irq_i(timer_irq_i),
        .ext_irq_i(ext_irq_i),
        .reset_vector_i(reset_vector_i),
        .ibus_adr_o(ia_a), .ibus_cyc_o(ic_a),
        .ibus_rdt_i(ibus_rdt_i), .ibus_ack_i(ibus_ack_i),
        .dbus_adr_o(da_a), .dbus_dat_o(dd_a), .dbus_sel_o(ds_a),
        .dbus_we_o(dw_a), .dbus_cyc_o(dc_a),
        .dbus_rdt_i(dbus_rdt_i), .dbus_ack_i(dbus_ack_i));
    zirh_vex_wrap u_b (
        .clk(clk), .rst_n(rst_n), .timer_irq_i(timer_irq_i),
        .ext_irq_i(ext_irq_i),
        .reset_vector_i(reset_vector_i),
        .ibus_adr_o(ia_b), .ibus_cyc_o(ic_b),
        .ibus_rdt_i(ibus_rdt_i), .ibus_ack_i(ibus_ack_i),
        .dbus_adr_o(da_b), .dbus_dat_o(dd_b), .dbus_sel_o(ds_b),
        .dbus_we_o(dw_b), .dbus_cyc_o(dc_b),
        .dbus_rdt_i(dbus_rdt_i), .dbus_ack_i(dbus_ack_i));
    zirh_vex_wrap u_c (
        .clk(clk), .rst_n(rst_n), .timer_irq_i(timer_irq_i),
        .ext_irq_i(ext_irq_i),
        .reset_vector_i(reset_vector_i),
        .ibus_adr_o(ia_c), .ibus_cyc_o(ic_c),
        .ibus_rdt_i(ibus_rdt_i), .ibus_ack_i(ibus_ack_i),
        .dbus_adr_o(da_c), .dbus_dat_o(dd_c), .dbus_sel_o(ds_c),
        .dbus_we_o(dw_c), .dbus_cyc_o(dc_c),
        .dbus_rdt_i(dbus_rdt_i), .dbus_ack_i(dbus_ack_i));

    zirh_voter #(.WIDTH(32)) u_v_ia (.a_i(ia_a), .b_i(ia_b), .c_i(ia_c), .y_o(ibus_adr_o));
    zirh_voter #(.WIDTH(32)) u_v_da (.a_i(da_a), .b_i(da_b), .c_i(da_c), .y_o(dbus_adr_o));
    zirh_voter #(.WIDTH(32)) u_v_dd (.a_i(dd_a), .b_i(dd_b), .c_i(dd_c), .y_o(dbus_dat_o));
    zirh_voter #(.WIDTH(4))  u_v_ds (.a_i(ds_a), .b_i(ds_b), .c_i(ds_c), .y_o(dbus_sel_o));
    zirh_voter #(.WIDTH(1))  u_v_ic (.a_i(ic_a), .b_i(ic_b), .c_i(ic_c), .y_o(ibus_cyc_o));
    zirh_voter #(.WIDTH(1))  u_v_dc (.a_i(dc_a), .b_i(dc_b), .c_i(dc_c), .y_o(dbus_cyc_o));
    zirh_voter #(.WIDTH(1))  u_v_dw (.a_i(dw_a), .b_i(dw_b), .c_i(dw_c), .y_o(dbus_we_o));

    wire mismatch =
        |((ia_a ^ ia_b) | (ia_b ^ ia_c)) |
        |((da_a ^ da_b) | (da_b ^ da_c)) |
        |((dd_a ^ dd_b) | (dd_b ^ dd_c)) |
        |((ds_a ^ ds_b) | (ds_b ^ ds_c)) |
        (ic_a ^ ic_b) | (ic_b ^ ic_c) |
        (dc_a ^ dc_b) | (dc_b ^ dc_c) |
        (dw_a ^ dw_b) | (dw_b ^ dw_c);

    always @(posedge clk) begin
        if (!rst_n)        err_o <= 1'b0;
        else if (mismatch) err_o <= 1'b1;   // sticky until reset
    end

endmodule

`default_nettype wire
