// =============================================================================
// ZIRH-3 - techmap bridge: memory_libmap generic cells to RM 2P macros
// pnr/vexlite/rm_macro_map.v                       (Cycle 15 round 4)
//
// Side A carries the write port, side B the read port; the macro's
// per-bit mask (A_BM) carries the libmap's per-bit write enables
// directly. BIST sides are tied off - the cache is refill-repairable
// by nature and the die's MBIST doorway covers the banks that need a
// march. A_DLY/B_DLY select the margined timing arc per the PDK
// datasheet default (1).
// =============================================================================

module ram_rm2p_512x32 (
    input  wire        PORT_W_CLK,
    input  wire [8:0]  PORT_W_ADDR,
    input  wire [31:0] PORT_W_WR_DATA,
    input  wire [31:0] PORT_W_WR_EN,
    input  wire        PORT_R_CLK,
    input  wire [8:0]  PORT_R_ADDR,
    input  wire        PORT_R_RD_EN,
    output wire [31:0] PORT_R_RD_DATA
);
    RM_IHPSG13_2P_512x32_c2_bm_bist u_m (
        .A_CLK(PORT_W_CLK), .A_MEN(1'b1), .A_WEN(|PORT_W_WR_EN),
        .A_REN(1'b0), .A_ADDR(PORT_W_ADDR), .A_DIN(PORT_W_WR_DATA),
        .A_DLY(1'b1), .A_DOUT(), .A_BM(PORT_W_WR_EN),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
        .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(9'd0),
        .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0),
        .B_CLK(PORT_R_CLK), .B_MEN(1'b1), .B_WEN(1'b0),
        .B_REN(PORT_R_RD_EN), .B_ADDR(PORT_R_ADDR), .B_DIN(32'd0),
        .B_DLY(1'b1), .B_DOUT(PORT_R_RD_DATA), .B_BM(32'd0),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0),
        .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(9'd0),
        .B_BIST_DIN(32'd0), .B_BIST_BM(32'd0));
endmodule

module ram_rm2p_64x32 (
    input  wire        PORT_W_CLK,
    input  wire [5:0]  PORT_W_ADDR,
    input  wire [31:0] PORT_W_WR_DATA,
    input  wire [31:0] PORT_W_WR_EN,
    input  wire        PORT_R_CLK,
    input  wire [5:0]  PORT_R_ADDR,
    input  wire        PORT_R_RD_EN,
    output wire [31:0] PORT_R_RD_DATA
);
    // the _c2 (no-BM) variant: whole-word writes only. The tag store
    // is written whole by the line loader, so the per-bit enables
    // reduce to their OR - asserted structurally by construction here
    RM_IHPSG13_2P_64x32_c2 u_m (
        .A_CLK(PORT_W_CLK), .A_MEN(1'b1), .A_WEN(|PORT_W_WR_EN),
        .A_REN(1'b0), .A_ADDR(PORT_W_ADDR), .A_DIN(PORT_W_WR_DATA),
        .A_DLY(1'b1), .A_DOUT(),
        .B_CLK(PORT_R_CLK), .B_MEN(1'b1), .B_WEN(1'b0),
        .B_REN(PORT_R_RD_EN), .B_ADDR(PORT_R_ADDR), .B_DIN(32'd0),
        .B_DLY(1'b1), .B_DOUT(PORT_R_RD_DATA));
endmodule
