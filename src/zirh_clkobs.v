// =============================================================================
// ZIRH product program - the clock-loss observer (PROGRAM.md C11)
// zirh_clkobs.v
//
// The external clock is a single point of failure the die cannot see
// from inside its own domain: when the clock stops, every flop that
// could report it stops with it. This observer lives on an
// INDEPENDENT ring-oscillator clock and watches the main domain's
// heartbeat from outside - the watchman does not sleep when the town
// does.
//
//   main domain   one toggle flop, flipping every cycle
//   RO domain     two-flop synchronizer, edge detector, and an idle
//                 counter: LOSS_RO_CYCLES of silence declare the
//                 clock lost (clk_ok_o drops, the sticky event sets,
//                 the loss counter increments); RECOVER_TOGGLES of
//                 observed activity restore clk_ok_o - the sticky
//                 event stays for telemetry until explicitly cleared
//
// All observer state is TMR on the RO clock. This module deliberately
// carries no `ZIRH_ASSERT: those sample on the MAIN clock, and the
// whole point here is that the main clock is the thing that dies -
// the suite drives the scenarios instead.
//
// The RO itself is not in this file: in the ASIC it is the same
// hand-instantiated SG13G2 loop discipline as zirh_env_ro (a
// product-chip wrapper binds it); in simulation and on any FPGA
// rehearsal ro_clk_i arrives as a genuinely independent clock, which
// is the honest way to test a clock-loss observer.
// =============================================================================

`default_nettype none

module zirh_clkobs #(
    parameter integer LOSS_RO_CYCLES  = 8,
    parameter integer RECOVER_TOGGLES = 4
) (
    // observed domain
    input  wire clk,
    input  wire rst_n,

    // observer domain
    input  wire ro_clk,
    input  wire ro_rst_n,
    input  wire clear_i,          // clear the sticky event (RO domain)

    output wire clk_ok_o,         // level, RO domain
    output wire evt_loss_o,       // sticky until clear_i
    output wire [3:0] loss_cnt_o, // loss events survived
    output wire err_o             // observer TMR mismatch
);

    localparam integer IW = $clog2(LOSS_RO_CYCLES + 1);
    localparam integer RW = $clog2(RECOVER_TOGGLES + 1);

    // --- main domain: the heartbeat -----------------------------------------
    reg hb_q;
    always @(posedge clk) begin
        if (!rst_n) hb_q <= 1'b0;
        else        hb_q <= ~hb_q;
    end

    // --- RO domain ----------------------------------------------------------
    reg [1:0] sync_q;
    reg       hb_prev;
    always @(posedge ro_clk) begin
        if (!ro_rst_n) begin
            sync_q  <= 2'b00;
            hb_prev <= 1'b0;
        end else begin
            sync_q  <= {sync_q[0], hb_q};
            hb_prev <= sync_q[1];
        end
    end
    wire beat = sync_q[1] ^ hb_prev;

    wire [IW-1:0] idle_q;
    reg  [IW-1:0] idle_d;
    wire          ok_q;
    reg           ok_d;
    wire [RW-1:0] rec_q;
    reg  [RW-1:0] rec_d;
    wire          stk_q;
    reg           stk_d;
    wire [3:0]    cnt_q;
    reg  [3:0]    cnt_d;

    wire e0, e1, e2, e3, e4;
    zirh_tmr_reg #(.WIDTH(IW)) u_idle (.clk(ro_clk), .rst_n(ro_rst_n),
        .en_i(1'b1), .d_i(idle_d), .q_o(idle_q), .err_o(e0));
    zirh_tmr_reg #(.WIDTH(1), .RESET_VALUE(1'b1)) u_ok (
        .clk(ro_clk), .rst_n(ro_rst_n),
        .en_i(1'b1), .d_i(ok_d), .q_o(ok_q), .err_o(e1));
    zirh_tmr_reg #(.WIDTH(RW)) u_rec (.clk(ro_clk), .rst_n(ro_rst_n),
        .en_i(1'b1), .d_i(rec_d), .q_o(rec_q), .err_o(e2));
    zirh_tmr_reg #(.WIDTH(1)) u_stk (.clk(ro_clk), .rst_n(ro_rst_n),
        .en_i(1'b1), .d_i(stk_d), .q_o(stk_q), .err_o(e3));
    zirh_tmr_reg #(.WIDTH(4)) u_cnt (.clk(ro_clk), .rst_n(ro_rst_n),
        .en_i(1'b1), .d_i(cnt_d), .q_o(cnt_q), .err_o(e4));

    assign err_o = e0 | e1 | e2 | e3 | e4;

    always @* begin
        idle_d = idle_q;
        ok_d   = ok_q;
        rec_d  = rec_q;
        stk_d  = stk_q;
        cnt_d  = cnt_q;

        if (beat) begin
            idle_d = {IW{1'b0}};
            if (!ok_q) begin
                rec_d = rec_q + {{(RW-1){1'b0}}, 1'b1};
                if (rec_q == RECOVER_TOGGLES[RW-1:0] - {{(RW-1){1'b0}}, 1'b1})
                    ok_d = 1'b1;
            end
        end else begin
            if (idle_q != LOSS_RO_CYCLES[IW-1:0])
                idle_d = idle_q + {{(IW-1){1'b0}}, 1'b1};
            if (idle_q == LOSS_RO_CYCLES[IW-1:0] - {{(IW-1){1'b0}}, 1'b1}
                && ok_q) begin
                ok_d  = 1'b0;
                rec_d = {RW{1'b0}};
                stk_d = 1'b1;
                if (cnt_q != 4'hF)
                    cnt_d = cnt_q + 4'd1;
            end
        end

        if (clear_i) stk_d = 1'b0;
    end

    assign clk_ok_o   = ok_q;
    assign evt_loss_o = stk_q;
    assign loss_cnt_o = cnt_q;

endmodule

`default_nettype wire
