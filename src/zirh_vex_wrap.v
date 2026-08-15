// =============================================================================
// ZIRH-3 - VexRiscv bus wrapper (Cycle 14: the compute upgrade)
// src/zirh_vex_wrap.v
//
// The vendored core already speaks Wishbone classic on both buses -
// the same contract the soc's slaves and single-master bus were built
// against - so this wrapper is thin on purpose: byte addresses from
// word addresses, CYC qualified by STB (a slave may only see a cycle
// the master means), tied-off interrupt and error inputs, and the
// runtime reset vector passed through. The interface shape mirrors
// serv_synth_wrapper so the soc swap is a like-for-like exchange.
//
// The core's reset is SYNCHRONOUS and ACTIVE-HIGH (SpinalHDL
// convention); the caller inverts its active-low rail once, here at
// the boundary, not per use.
// =============================================================================

`default_nettype none

module zirh_vex_wrap (
    input  wire        clk,
    input  wire        rst_n,            // active low, inverted here once
    input  wire        timer_irq_i,
    input  wire [31:0] reset_vector_i,

    // instruction bus (wishbone classic, read-only)
    output wire [31:0] ibus_adr_o,
    output wire        ibus_cyc_o,
    input  wire [31:0] ibus_rdt_i,
    input  wire        ibus_ack_i,

    // data bus (wishbone classic)
    output wire [31:0] dbus_adr_o,
    output wire [31:0] dbus_dat_o,
    output wire [3:0]  dbus_sel_o,
    output wire        dbus_we_o,
    output wire        dbus_cyc_o,
    input  wire [31:0] dbus_rdt_i,
    input  wire        dbus_ack_i
);

    wire        icyc, istb, dcyc, dstb;
    wire [29:0] iadr, dadr;

    assign ibus_adr_o = {iadr, 2'b00};
    assign ibus_cyc_o = icyc & istb;
    assign dbus_adr_o = {dadr, 2'b00};
    assign dbus_cyc_o = dcyc & dstb;

    VexRiscv u_core (
        .externalResetVector   (reset_vector_i),
        .timerInterrupt        (timer_irq_i),
        .softwareInterrupt     (1'b0),
        .externalInterruptArray(32'd0),
        .iBusWishbone_CYC      (icyc),
        .iBusWishbone_STB      (istb),
        .iBusWishbone_ACK      (ibus_ack_i),
        .iBusWishbone_WE       (),
        .iBusWishbone_ADR      (iadr),
        .iBusWishbone_DAT_MISO (ibus_rdt_i),
        .iBusWishbone_DAT_MOSI (),
        .iBusWishbone_SEL      (),
        .iBusWishbone_ERR      (1'b0),
        .iBusWishbone_CTI      (),
        .iBusWishbone_BTE      (),
        .dBusWishbone_CYC      (dcyc),
        .dBusWishbone_STB      (dstb),
        .dBusWishbone_ACK      (dbus_ack_i),
        .dBusWishbone_WE       (dbus_we_o),
        .dBusWishbone_ADR      (dadr),
        .dBusWishbone_DAT_MISO (dbus_rdt_i),
        .dBusWishbone_DAT_MOSI (dbus_dat_o),
        .dBusWishbone_SEL      (dbus_sel_o),
        .dBusWishbone_ERR      (1'b0),
        .dBusWishbone_CTI      (),
        .dBusWishbone_BTE      (),
        .clk                   (clk),
        .reset                 (~rst_n)
    );

endmodule

`default_nettype wire
