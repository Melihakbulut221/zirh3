// =============================================================================
// ZIRH-3 - the timer/PWM bank at VORAGO parity (Cycle 30)
// src/zirh_timer.v
//
// The VA108x0 yardstick carries 24 configurable 32-bit counter/timers
// with compare, capture, PWM and pulse counting, pinned out through
// the GPIO ports as alternate functions. This bank matches the count
// and the pin philosophy at bus slot 7 (0x7000): PORTB's 24 pins each
// carry timer i's PWM output when the ALTB bit says so, and capture
// and pulse modes LISTEN to the same pins - zero new pads.
//
// Flight discipline: every register that holds state - control,
// reload, compare, the running counter, the capture latch - is a
// voted-feedback TMR register, because a flipped counter bit is a
// wrong period until the next reload and a flipped compare bit is a
// wrong duty forever; all faults land in err_o like every control
// register on this die. Capture inputs cross two flops first.
//
// Per-timer word map (stride 0x20, timer i at 0x20*i, i = 0..23):
//   +0x00 CTRL   {irq_en, mode[1:0], en}  (write also loads COUNT)
//   +0x04 RELOAD period / wrap top
//   +0x08 CMP    PWM compare
//   +0x0C COUNT  (RO)
//   +0x10 CAP    (RO, capture latch)
//   +0x14 STAT   {cap_valid, ovf}  (write 1 to clear)
// Global:
//   0x780 ALTB   [23:0] - PORTB pin i drives PWM i when set
//
// Modes: 0 = timer (down from RELOAD, wrap sets ovf), 1 = pwm (up to
// RELOAD, out = COUNT < CMP), 2 = capture (free-run up; rising pin
// edge latches COUNT into CAP), 3 = pulse (COUNT counts rising pin
// edges). Timer 0's ovf & irq_en drives the core's timer interrupt -
// masked by the RISC-V core until software asks, so wiring it is
// capability, not risk.
// =============================================================================

`default_nettype none

module zirh_timer #(
    parameter integer N = 24
) (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave (slot 7)
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // pin side: PWM out per timer, capture/pulse listen per timer
    output wire [N-1:0] pwm_o,
    output wire [N-1:0] alt_o,        // PORTB alt-function select
    input  wire [N-1:0] cap_i,

    output wire        timer_irq_o,   // timer 0, gated by its irq_en
    output wire        err_o          // own TMR mismatch, pulse
);

    localparam [1:0] M_TIMER = 2'd0, M_PWM = 2'd1,
                     M_CAP   = 2'd2, M_PULSE = 2'd3;

    wire [4:0] t_sel   = adr_i[9:5];
    wire [2:0] reg_sel = adr_i[4:2];
    wire       g_altb  = (adr_i[11:2] == 10'h1E0);   // 0x780

    // bus writes last two cycles: load once
    reg wr_seen;
    always @(posedge clk) begin
        if (!rst_n) wr_seen <= 1'b0;
        else        wr_seen <= cyc_i & we_i;
    end
    wire wr_fire = cyc_i & we_i & ~wr_seen;

    // pin synchronizers
    reg [N-1:0] cap_s0, cap_s1, cap_s2;
    always @(posedge clk) begin
        cap_s0 <= cap_i;
        cap_s1 <= cap_s0;
        cap_s2 <= cap_s1;
    end
    wire [N-1:0] cap_edge = cap_s1 & ~cap_s2;

    // the ALTB register: which PORTB pins the bank owns
    wire [N-1:0] altb_q;
    wire         altb_err;
    zirh_tmr_reg #(.WIDTH(N)) u_altb (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & g_altb),
        .d_i(dat_i[N-1:0]),
        .q_o(altb_q), .err_o(altb_err));
    assign alt_o = altb_q;

    wire [31:0] rdt_t   [0:N-1];
    wire [N-1:0] t_err;
    wire [N-1:0] t_irq;
    genvar gi;
    generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_t
        wire sel     = ~g_altb & (t_sel == gi[4:0]);
        wire wr      = wr_fire & sel;

        wire [3:0]  ctrl_q;
        wire [31:0] rld_q, cmp_q, cnt_q, cap_q;
        wire [1:0]  stat_q;
        wire        e_ctrl, e_rld, e_cmp, e_cnt, e_cap, e_stat;

        wire        en   = ctrl_q[0];
        wire [1:0]  mode = ctrl_q[2:1];
        wire        irqe = ctrl_q[3];

        zirh_tmr_reg #(.WIDTH(4)) u_ctrl (
            .clk(clk), .rst_n(rst_n),
            .en_i(wr & (reg_sel == 3'd0)),
            .d_i(dat_i[3:0]), .q_o(ctrl_q), .err_o(e_ctrl));

        zirh_tmr_reg #(.WIDTH(32)) u_rld (
            .clk(clk), .rst_n(rst_n),
            .en_i(wr & (reg_sel == 3'd1)),
            .d_i(dat_i), .q_o(rld_q), .err_o(e_rld));

        zirh_tmr_reg #(.WIDTH(32)) u_cmp (
            .clk(clk), .rst_n(rst_n),
            .en_i(wr & (reg_sel == 3'd2)),
            .d_i(dat_i), .q_o(cmp_q), .err_o(e_cmp));

        // the running counter: a CTRL write loads it (RELOAD for the
        // down-counter, zero for the rest), so enable and a known
        // phase arrive in one bus write
        reg [31:0] cnt_d;
        wire wrap_dn = (cnt_q == 32'd0);
        wire wrap_up = (cnt_q >= rld_q);
        always @* begin
            cnt_d = cnt_q;
            if (en) begin
                case (mode)
                    M_TIMER: cnt_d = wrap_dn ? rld_q : cnt_q - 32'd1;
                    M_PWM:   cnt_d = wrap_up ? 32'd0 : cnt_q + 32'd1;
                    M_CAP:   cnt_d = cnt_q + 32'd1;
                    default: cnt_d = cnt_q + {31'd0, cap_edge[gi]};
                endcase
            end
        end
        wire [31:0] cnt_load = (dat_i[2:1] == M_TIMER) ? rld_q : 32'd0;
        zirh_tmr_reg #(.WIDTH(32)) u_cnt (
            .clk(clk), .rst_n(rst_n),
            .en_i(1'b1),
            .d_i((wr & (reg_sel == 3'd0)) ? cnt_load : cnt_d),
            .q_o(cnt_q), .err_o(e_cnt));

        zirh_tmr_reg #(.WIDTH(32)) u_cap (
            .clk(clk), .rst_n(rst_n),
            .en_i(en & (mode == M_CAP) & cap_edge[gi]),
            .d_i(cnt_q), .q_o(cap_q), .err_o(e_cap));

        // sticky status, write-1-to-clear
        wire ovf_set = en & ((mode == M_TIMER) ? wrap_dn :
                             (mode == M_PWM)   ? wrap_up : 1'b0);
        wire cap_set = en & (mode == M_CAP) & cap_edge[gi];
        wire stat_wr = wr & (reg_sel == 3'd5);
        zirh_tmr_reg #(.WIDTH(2)) u_stat (
            .clk(clk), .rst_n(rst_n),
            .en_i(ovf_set | cap_set | stat_wr),
            .d_i({(stat_q[1] & ~(stat_wr & dat_i[1])) | cap_set,
                  (stat_q[0] & ~(stat_wr & dat_i[0])) | ovf_set}),
            .q_o(stat_q), .err_o(e_stat));

        assign pwm_o[gi] = en & (mode == M_PWM) & (cnt_q < cmp_q);
        assign t_irq[gi] = irqe & stat_q[0];
        assign t_err[gi] = e_ctrl | e_rld | e_cmp | e_cnt | e_cap | e_stat;

        assign rdt_t[gi] =
            (reg_sel == 3'd0) ? {28'h0, ctrl_q} :
            (reg_sel == 3'd1) ? rld_q :
            (reg_sel == 3'd2) ? cmp_q :
            (reg_sel == 3'd3) ? cnt_q :
            (reg_sel == 3'd4) ? cap_q :
            {30'h0, stat_q};
    end
    endgenerate

    assign rdt_o = g_altb ? {{(32-N){1'b0}}, altb_q}
                 : (t_sel < N[4:0]) ? rdt_t[t_sel[4:0]]
                 : 32'h0;

    assign timer_irq_o = t_irq[0];
    assign err_o       = altb_err | (|t_err);
    assign ack_o       = cyc_i;

endmodule

`default_nettype wire
