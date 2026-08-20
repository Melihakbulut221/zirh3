// =============================================================================
// ZIRH-3 - GPIO at VORAGO parity (Cycle 27)
// src/zirh_gpio.v
//
// The VA108x0 yardstick carries 56 configurable GPIO on two ports
// (PORTA 32, PORTB 24); this block matches the count and the split at
// bus slot 6 (0x6000). Flight discipline over feature count:
//
//   * OUT and DIR are TMR'd - a flipped direction bit mid-flight
//     turns an input pin into a fighting driver, a flipped output bit
//     lies to whatever the pin commands; both faults land in the
//     err_o aggregate like every control register on this die
//   * IN is double-synchronized per port - pins are asynchronous by
//     definition and a metastable read is a software lottery
//   * no set/clear alias registers: software read-modify-writes, and
//     the register file stays small enough to reason about
//
// Word map (adr[4:2]):
//   0x00 PORTA_OUT (RW)   0x04 PORTA_DIR (RW, 1 = drive)   0x08 PORTA_IN (RO)
//   0x0C PORTB_OUT (RW)   0x10 PORTB_DIR (RW)              0x14 PORTB_IN (RO)
//
// The pad ring binds o/oe/i triples into 56 bidirectional pads at
// hardening time; until then the triples are the top's honest truth.
// =============================================================================

`default_nettype none

module zirh_gpio (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave (slot 6)
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // PORTA, 32 pins
    input  wire [31:0] gpio_a_i,
    output wire [31:0] gpio_a_o,
    output wire [31:0] gpio_a_oe,

    // PORTB, 24 pins
    input  wire [23:0] gpio_b_i,
    output wire [23:0] gpio_b_o,
    output wire [23:0] gpio_b_oe,

    output wire        err_o          // own TMR mismatch, pulse
);

    wire [2:0] reg_sel = adr_i[4:2];

    // bus writes last two cycles: load each register exactly once
    reg wr_seen;
    always @(posedge clk) begin
        if (!rst_n) wr_seen <= 1'b0;
        else        wr_seen <= cyc_i & we_i;
    end
    wire wr_fire = cyc_i & we_i & ~wr_seen;

    wire [31:0] a_out_q, a_dir_q;
    wire [23:0] b_out_q, b_dir_q;
    wire        a_out_err, a_dir_err, b_out_err, b_dir_err;

    zirh_tmr_reg #(.WIDTH(32)) u_a_out (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd0)),
        .d_i(dat_i),
        .q_o(a_out_q), .err_o(a_out_err));

    zirh_tmr_reg #(.WIDTH(32)) u_a_dir (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd1)),
        .d_i(dat_i),
        .q_o(a_dir_q), .err_o(a_dir_err));

    zirh_tmr_reg #(.WIDTH(24)) u_b_out (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd3)),
        .d_i(dat_i[23:0]),
        .q_o(b_out_q), .err_o(b_out_err));

    zirh_tmr_reg #(.WIDTH(24)) u_b_dir (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd4)),
        .d_i(dat_i[23:0]),
        .q_o(b_dir_q), .err_o(b_dir_err));

    // pins are asynchronous; two flops per port before software sees them
    reg [31:0] a_sync0, a_sync1;
    reg [23:0] b_sync0, b_sync1;
    always @(posedge clk) begin
        a_sync0 <= gpio_a_i;
        a_sync1 <= a_sync0;
        b_sync0 <= gpio_b_i;
        b_sync1 <= b_sync0;
    end

    assign gpio_a_o  = a_out_q;
    assign gpio_a_oe = a_dir_q;
    assign gpio_b_o  = b_out_q;
    assign gpio_b_oe = b_dir_q;

    assign err_o = a_out_err | a_dir_err | b_out_err | b_dir_err;

    assign rdt_o =
        (reg_sel == 3'd0) ? a_out_q :
        (reg_sel == 3'd1) ? a_dir_q :
        (reg_sel == 3'd2) ? a_sync1 :
        (reg_sel == 3'd3) ? {8'h0, b_out_q} :
        (reg_sel == 3'd4) ? {8'h0, b_dir_q} :
        {8'h0, b_sync1};

    assign ack_o = cyc_i;

endmodule

`default_nettype wire
