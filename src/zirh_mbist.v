// =============================================================================
// ZIRH-3 - the MBIST doorway (F28: design for test)
// src/zirh_mbist.v
//
// The sliced SECDED bank has carried a full march-test engine since its
// own bring-up (zirh_sram_bist: march c-, checkerboard fill, read-scan) -
// but until now its control pins were tied off at the top. This block is
// the doorway: one small bus slave at slot 5 (0x5000) that lets SOFTWARE
// run the memory test - a manufacturing-test program arrives over the
// ISP like any other image ("the test program is data too"), and an
// in-flight self-test is one firmware loop away.
//
// Register map (word offsets in slot 5, base 0x5000):
//   0x00 CTRL RW  write: bit0 = start (one-shot, ignored while busy),
//                        bits[2:1] = mode (0 march c-, 1 cb fill,
//                        2 read-scan)
//                 read:  {busy, pass, 28'h0, mode}
//   0x04 CNT  RO  {16'h0, fail_cnt}
//   0x08 FAIL RO  {12'h0, fail_map[4:0], 5'h0, fail_adr[9:0]} - the raw
//                 per-macro MBU-style record, same shape the beam
//                 instrument streams
//   0x0C PAGE RW  [5:0] the bank page the CPU's slot-4 window (and
//                 this doorway's BIST steering) currently shows -
//                 how 4 KB of bus map reaches 64 KB of bank
//
// The CTRL read word is shaped for a branchless verdict: bits [31:30]
// are {busy, pass}, so (CTRL >> 30) is 1 exactly when the test is done
// and clean - a loaded program can turn that into a UART byte with one
// shift and one add, no branches needed (SERV-friendly).
//
// A march test OWNS the array while it runs: software must not touch the
// bank while busy - the busy bit is the contract. The mode register is
// TMR'd (a flipped mode mid-campaign would silently change what "pass"
// means); everything else here is a pulse or a pass-through of the
// engine's own TMR'd state.
// =============================================================================

`default_nettype none

module zirh_mbist (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave (slot 5)
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // to/from the bank's BIST engine
    output wire        bist_start_o,
    output wire [1:0]  bist_mode_o,
    input  wire        bist_busy_i,
    input  wire        bist_pass_i,
    input  wire [15:0] bist_fail_cnt_i,
    input  wire [11:0] bist_fail_adr_i,
    input  wire [4:0]  bist_fail_map_i,

    output wire [5:0]  page_o,        // bank page for the CPU window

    output wire        err_o          // own TMR mismatch, pulse
);

    wire [1:0] reg_sel = adr_i[3:2];
    wire wr_ctrl = cyc_i & we_i & (reg_sel == 2'd0);
    wire wr_page = cyc_i & we_i & (reg_sel == 2'd3);

    // bus writes last two cycles: fire the start exactly once, and only
    // when the engine is idle (a start mid-run would restart the march
    // and turn a half-tested array into a "pass")
    reg wr_seen;
    always @(posedge clk) begin
        if (!rst_n) wr_seen <= 1'b0;
        else        wr_seen <= wr_ctrl;
    end
    assign bist_start_o = wr_ctrl & ~wr_seen & dat_i[0] & ~bist_busy_i;

    // the mode register: TMR'd, loaded on the same CTRL write
    wire [1:0] mode_q;
    wire       mode_err;
    zirh_tmr_reg #(.WIDTH(2)) u_mode (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_ctrl & ~wr_seen & ~bist_busy_i),
        .d_i(dat_i[2:1]),
        .q_o(mode_q), .err_o(mode_err));

    // the page register: TMR'd - a flipped page mid-flight would move
    // the software's entire data window
    wire [5:0] page_q;
    wire       page_err;
    zirh_tmr_reg #(.WIDTH(6)) u_page (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_page & ~wr_seen),
        .d_i(dat_i[5:0]),
        .q_o(page_q), .err_o(page_err));

    assign page_o      = page_q;
    assign bist_mode_o = mode_q;
    assign err_o       = mode_err | page_err;

    assign rdt_o =
        (reg_sel == 2'd0) ? {bist_busy_i, bist_pass_i, 28'h0, mode_q} :
        (reg_sel == 2'd1) ? {16'h0, bist_fail_cnt_i} :
        (reg_sel == 2'd2) ? {12'h0, bist_fail_map_i, 3'h0, bist_fail_adr_i} :
        {26'h0, page_q};

    assign ack_o = cyc_i;

endmodule

`default_nettype wire
