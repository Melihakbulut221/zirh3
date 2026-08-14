// =============================================================================
// ZIRH product program P2 - the march/BIST engine over the macro BIST ports
// zirh_sram_bist.v
//
// One block, three customers (docs/DEBUG-DFT.md):
//   production  MARCH C- over all five slices in parallel - the
//               screening step qualification asks for (F28)
//   flight      the same march, commanded as a self-test through the
//               chip's register window (BIST is destructive: the
//               scrubber's boot-init discipline reruns after)
//   science     checkerboard fill + read-only scan: the A6 beam
//               pattern-scan front end - the scan REPORTS mismatches
//               and never repairs, because a repair would erase the
//               event the beam experiment exists to count. Fail
//               address and slice map are latched raw for MBU
//               correlation.
//
// The engine drives the RM_IHPSG13 A_BIST_* port set the macros ship
// with; A_BIST_EN muxes the array away from the functional port, so
// BIST is exclusive by construction. All engine state is TMR with the
// safe-state trap landing on IDLE (a mangled test engine must never
// keep scribbling on the array).
//
// MARCH C- element table (solid backgrounds, W = 0x00, ~W = 0xFF):
//   up(w0)  up(r0,w1)  up(r1,w0)  down(r0,w1)  down(r1,w0)  down(r0)
// Each op takes two cycles (issue / settle-compare-or-advance); reads
// compare all five slices against the expected background and any
// mismatch latches the address, the per-slice fail map and counts.
// =============================================================================

`default_nettype none

module zirh_sram_bist #(
    parameter integer ADDR_W = 10
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_i,
    input  wire [1:0]  mode_i,      // 0 march c-, 1 cb fill, 2 read-scan

    input  wire [7:0]  q0_i,
    input  wire [7:0]  q1_i,
    input  wire [7:0]  q2_i,
    input  wire [7:0]  q3_i,
    input  wire [7:0]  q4_i,

    output wire        bist_en_o,
    output wire        bist_men_o,
    output wire        bist_wen_o,
    output wire        bist_ren_o,
    output wire [ADDR_W-1:0] bist_adr_o,
    output wire [7:0]  bist_din_o,

    output wire        busy_o,
    output wire        pass_o,
    output wire [15:0] fail_cnt_o,
    output wire [ADDR_W-1:0] fail_adr_o,
    output wire [4:0]  fail_map_o,
    output wire        err_o
);

    localparam [ADDR_W-1:0] A_MAX = {ADDR_W{1'b1}};

    // --- march element table -------------------------------------------------
    // {dir_down, has_rd, rd_ones, has_wr, wr_ones}
    function [4:0] elem;
        input [2:0] i;
        begin
            case (i)
                3'd0:    elem = 5'b0_0_0_1_0;   // up    w0
                3'd1:    elem = 5'b0_1_0_1_1;   // up    r0 w1
                3'd2:    elem = 5'b0_1_1_1_0;   // up    r1 w0
                3'd3:    elem = 5'b1_1_0_1_1;   // down  r0 w1
                3'd4:    elem = 5'b1_1_1_1_0;   // down  r1 w0
                default: elem = 5'b1_1_0_0_0;   // down  r0
            endcase
        end
    endfunction
    localparam [2:0] LAST_ELEM = 3'd5;

    // --- state ---------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_RD = 3'd1, S_CHK = 3'd2,
                     S_WR   = 3'd3, S_ADV = 3'd4, S_DONE = 3'd5;

    wire [2:0] st_q;   reg [2:0] st_d;
    wire [2:0] el_q;   reg [2:0] el_d;
    wire [ADDR_W-1:0] ad_q; reg [ADDR_W-1:0] ad_d;
    wire [1:0]  md_q;  reg [1:0]  md_d;
    wire [15:0] fc_q;  reg [15:0] fc_d;
    wire [ADDR_W-1:0] fa_q; reg [ADDR_W-1:0] fa_d;
    wire [4:0]  fm_q;  reg [4:0]  fm_d;
    wire        pa_q;  reg        pa_d;

    wire e0, e1, e2, e3, e4, e5, e6, e7;
    zirh_tmr_reg #(.WIDTH(3))      u_st (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(st_d), .q_o(st_q), .err_o(e0));
    zirh_tmr_reg #(.WIDTH(3))      u_el (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(el_d), .q_o(el_q), .err_o(e1));
    zirh_tmr_reg #(.WIDTH(ADDR_W)) u_ad (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(ad_d), .q_o(ad_q), .err_o(e2));
    zirh_tmr_reg #(.WIDTH(2))      u_md (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(md_d), .q_o(md_q), .err_o(e3));
    zirh_tmr_reg #(.WIDTH(16))     u_fc (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(fc_d), .q_o(fc_q), .err_o(e4));
    zirh_tmr_reg #(.WIDTH(ADDR_W)) u_fa (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(fa_d), .q_o(fa_q), .err_o(e5));
    zirh_tmr_reg #(.WIDTH(5))      u_fm (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(fm_d), .q_o(fm_q), .err_o(e6));
    zirh_tmr_reg #(.WIDTH(1))      u_pa (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(pa_d), .q_o(pa_q), .err_o(e7));

    assign err_o = e0 | e1 | e2 | e3 | e4 | e5 | e6 | e7;

    // --- expected data -------------------------------------------------------
    // march: solid background per element table; cb/scan: checkerboard
    // by address parity (0x55/0xAA), the classic beam background
    wire [4:0] E  = elem(el_q);
    wire [4:0] En = elem(el_q + 3'd1);   // next element, for the handoff
    wire dirdn   = E[4];
    wire has_rd  = E[3];
    wire rd_ones = E[2];
    wire has_wr  = E[1];
    wire wr_ones = E[0];

    wire [7:0] cb_pat    = ad_q[0] ? 8'hAA : 8'h55;
    wire [7:0] march_rd  = rd_ones ? 8'hFF : 8'h00;
    wire [7:0] march_wr  = wr_ones ? 8'hFF : 8'h00;
    wire       is_march  = (md_q == 2'd0);
    wire [7:0] exp_val   = is_march ? march_rd : cb_pat;

    wire [4:0] miss = {(q4_i != exp_val), (q3_i != exp_val),
                       (q2_i != exp_val), (q1_i != exp_val),
                       (q0_i != exp_val)};

    // --- port drive ----------------------------------------------------------
    assign bist_en_o  = (st_q != S_IDLE) & (st_q != S_DONE);
    assign bist_men_o = bist_en_o;
    assign bist_ren_o = (st_q == S_RD);
    assign bist_wen_o = (st_q == S_WR);
    assign bist_adr_o = ad_q;
    assign bist_din_o = is_march ? march_wr : cb_pat;

    assign busy_o     = bist_en_o;
    assign pass_o     = pa_q;
    assign fail_cnt_o = fc_q;
    assign fail_adr_o = fa_q;
    assign fail_map_o = fm_q;

    // --- FSM -----------------------------------------------------------------
    wire [ADDR_W-1:0] ad_first = (is_march & dirdn) ? A_MAX : {ADDR_W{1'b0}};
    wire [ADDR_W-1:0] ad_last  = (is_march & dirdn) ? {ADDR_W{1'b0}} : A_MAX;
    wire [ADDR_W-1:0] ad_next  = (is_march & dirdn) ? ad_q - {{(ADDR_W-1){1'b0}}, 1'b1}
                                                    : ad_q + {{(ADDR_W-1){1'b0}}, 1'b1};

    // per-element entry state: read first if the element reads, else write
    wire [2:0] entry = (is_march & ~has_rd) ? S_WR
                     : (md_q == 2'd1)       ? S_WR      // cb fill writes only
                     :                        S_RD;     // march r-first / scan

    always @* begin
        st_d = st_q;  el_d = el_q;  ad_d = ad_q;  md_d = md_q;
        fc_d = fc_q;  fa_d = fa_q;  fm_d = fm_q;  pa_d = pa_q;

        case (st_q)
            S_IDLE: begin
                if (start_i) begin
                    md_d = mode_i;
                    el_d = 3'd0;
                    fc_d = 16'd0;
                    fm_d = 5'd0;
                    pa_d = 1'b0;
                    // first address depends on mode/element 0 (always up)
                    ad_d = {ADDR_W{1'b0}};
                    st_d = (mode_i == 2'd1) ? S_WR
                         : (mode_i == 2'd2) ? S_RD
                         :                    S_WR;   // march elem0 = w0
                end
            end

            S_RD:  st_d = S_CHK;          // read issued; data next cycle

            S_CHK: begin
                if (|miss) begin
                    if (fc_q != 16'hFFFF)
                        fc_d = fc_q + 16'd1;
                    fa_d = ad_q;
                    fm_d = miss;
                end
                st_d = (is_march & has_wr) ? S_WR : S_ADV;
            end

            S_WR:  st_d = S_ADV;

            S_ADV: begin
                if (ad_q == ad_last && !(is_march)) begin
                    pa_d = (fc_q == 16'd0);
                    st_d = S_DONE;
                end else if (is_march && ad_q == ad_last) begin
                    if (el_q == LAST_ELEM) begin
                        pa_d = (fc_q == 16'd0);
                        st_d = S_DONE;
                    end else begin
                        el_d = el_q + 3'd1;
                        // next element's direction picks its first adr
                        ad_d = En[4] ? A_MAX : {ADDR_W{1'b0}};
                        st_d = En[3] ? S_RD : S_WR;
                    end
                end else begin
                    ad_d = ad_next;
                    st_d = is_march ? (has_rd ? S_RD : S_WR) : entry;
                end
            end

            S_DONE: if (!start_i) st_d = S_IDLE;

            default: st_d = S_IDLE;       // safe-state trap: stop touching
                                          // the array, report nothing false
        endcase
    end

    `include "zirh_assert.vh"
    // engine never touches the array outside its active states, and
    // the element index stays inside the march table
    `ZIRH_ASSERT(a_state_legal, st_q <= S_DONE)
    `ZIRH_ASSERT(a_wen_gated, !bist_wen_o || busy_o)
    `ZIRH_ASSERT(a_elem_legal, el_q <= LAST_ELEM)

endmodule

`default_nettype wire
