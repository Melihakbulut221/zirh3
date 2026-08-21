// =============================================================================
// ZIRH-3 - the interrupt fabric (Cycle 34)
// src/zirh_irq.v
//
// The yardstick routes every peripheral into an NVIC through an IRQ
// selector; this die's core has carried a tied-off 32-line external
// interrupt array since the day it arrived. This block gives those
// lines meaning: thirty-two LEVEL sources - every flag already lives
// sticky and write-1-to-clear at its own peripheral, so the fabric
// latches nothing and can lose nothing - one TMR'd mask, a readable
// pending word, and the masked lines straight into the core.
//
// Source map:
//   [23:0]  timer 0..23 overflow (each gated by its own irq_en)
//   [24]    UART1 rx_valid
//   [25]    UART1 tx-queue room (not full)
//   [26]    I2C0 ready     [27] I2C1 ready
//   [28]    SPI0 tx-queue room   [29] SPI1   [30] SPI2
//   [31]    reserved, reads zero
//
// Word map (slot 6, 0x6400):
//   +0x00 MASK    (RW, TMR)
//   +0x04 RAW     (RO - the world as it is)
//   +0x08 PENDING (RO - RAW & MASK, what the core sees)
// =============================================================================

`default_nettype none

module zirh_irq (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    input  wire [31:0] raw_i,
    output wire [31:0] pending_o,

    output wire        err_o
);

    wire [1:0] reg_sel = adr_i[3:2];

    reg wr_seen;
    always @(posedge clk) begin
        if (!rst_n) wr_seen <= 1'b0;
        else        wr_seen <= cyc_i & we_i;
    end
    wire wr_fire = cyc_i & we_i & ~wr_seen;

    wire [31:0] mask_q;
    wire        e_mask;
    zirh_tmr_reg #(.WIDTH(32)) u_mask (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 2'd0)),
        .d_i(dat_i), .q_o(mask_q), .err_o(e_mask));

    assign pending_o = raw_i & mask_q;

    assign rdt_o =
        (reg_sel == 2'd0) ? mask_q :
        (reg_sel == 2'd1) ? raw_i :
        pending_o;

    assign ack_o = cyc_i;
    assign err_o = e_mask;

endmodule

`default_nettype wire
