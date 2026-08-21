// =============================================================================
// ZIRH-3 - the second UART (Cycle 33, deepened Cycle 35)
// src/zirh_uart1.v
//
// The payload's serial port: a programmable endpoint on PORTA
// alternate functions, baud set by software, owned by software,
// nothing else riding it. Cycle 35 gives it the yardstick's depth:
// sixteen-deep TMR'd FIFOs on both directions, programmable parity
// and a second stop bit, and honest sticky flags for the three ways
// a serial link lies - overrun, bad frame, bad parity.
//
// The laws, each earned:
//   - TXD writes QUEUE; the engine launches frames on its own while
//     bytes wait. A write to a full queue is refused - tx_full is
//     readable and software that will not check it cannot be saved
//     by a flag it also will not check.
//   - an arriving byte enters the RX queue only if its frame was
//     honest: stop bit high (else FERR), parity matching when
//     enabled (else PERR). A byte arriving at a full queue is
//     DROPPED and OE goes sticky - the oldest data survives,
//     because in flight the unread past explains the present.
//   - the flags are write-1-to-clear through STAT, like the timer
//     bank's; nothing else in STAT is writable.
//   - 8N1 with the defaults is bit-for-bit the Cycle 33 frame; the
//     second stop bit is transmit timing only (the receiver checks
//     the first stop, as receivers do).
//
// Word map:
//   +0x00 CTRL {stop2, podd, pen, en}   enable leases PORTA 16/17
//   +0x04 DIV                           bit period in clk cycles
//   +0x08 TXD  write pushes the TX queue (refused when full)
//   +0x0C RXD  (RO) read pops the RX queue
//   +0x10 STAT {tx_lvl[20:16], rx_lvl[12:8],
//               perr[6], ferr[5], oe[4]      (W1C),
//               rx_full[3], tx_full[2], rx_valid[1], tip[0]}
// =============================================================================

`default_nettype none

module zirh_uart1 (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    output wire        tx_o,
    input  wire        rx_i,
    output wire        lease_o,
    output wire        irq_rx_o,      // a byte waits
    output wire        irq_tx_o,      // the queue has room

    output wire        err_o
);

    wire [2:0] reg_sel = adr_i[4:2];

    reg wr_seen, rd_seen;
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_seen <= 1'b0;
            rd_seen <= 1'b0;
        end else begin
            wr_seen <= cyc_i & we_i;
            rd_seen <= cyc_i & ~we_i;
        end
    end
    wire wr_fire = cyc_i & we_i & ~wr_seen;
    wire rd_fire = cyc_i & ~we_i & ~rd_seen;

    reg [1:0] rx_s;
    always @(posedge clk) rx_s <= {rx_s[0], rx_i};
    wire rx_in = rx_s[1];

    wire [3:0]  ctrl_q;
    wire [15:0] div_q;
    wire        e_ctrl, e_div;
    zirh_tmr_reg #(.WIDTH(4)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd0)),
        .d_i(dat_i[3:0]), .q_o(ctrl_q), .err_o(e_ctrl));
    zirh_tmr_reg #(.WIDTH(16)) u_div (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd1)),
        .d_i(dat_i[15:0]), .q_o(div_q), .err_o(e_div));
    wire en    = ctrl_q[0];
    wire pen   = ctrl_q[1];
    wire podd  = ctrl_q[2];
    wire stop2 = ctrl_q[3];

    // ------------------------------------------------------------- TX queue
    wire [7:0] tf_rdat;
    wire       tf_empty, tf_full, e_tf;
    wire [4:0] tf_level;
    wire       tx_go;
    zirh_fifo #(.WIDTH(8), .DEPTH_LOG2(4)) u_txf (
        .clk(clk), .rst_n(rst_n),
        .wr_i(wr_fire & (reg_sel == 3'd2) & en),
        .wdat_i(dat_i[7:0]),
        .rd_i(tx_go), .rdat_o(tf_rdat),
        .empty_o(tf_empty), .full_o(tf_full), .level_o(tf_level),
        .err_o(e_tf));

    // ---------------------------------------------------------- TX engine
    // frame = start(0), d0..d7 lsb first, [parity], stop(1), [stop 2];
    // tx idles high; with pen=stop2=0 this is exactly the 8N1 of old
    wire        ttip_q, txl_q, txp_q;
    wire [7:0]  tsh_q;
    wire [3:0]  tbit_q;
    wire [15:0] tcnt_q;
    reg         ttip_d, txl_d, txp_d;
    reg  [7:0]  tsh_d;
    reg  [3:0]  tbit_d;
    reg  [15:0] tcnt_d;
    wire e_ttip, e_txl, e_txp, e_tsh, e_tbit, e_tcnt;

    assign tx_go = en & ~ttip_q & ~tf_empty;
    wire t_tick  = (tcnt_q == 16'd0);
    // the frame's last counted position: stop lands at 9, parity and
    // the second stop each push it one later
    wire [3:0] t_end = 4'd9 + {3'd0, pen} + {3'd0, stop2};

    always @* begin
        ttip_d = ttip_q;
        txl_d  = txl_q;
        txp_d  = txp_q;
        tsh_d  = tsh_q;
        tbit_d = tbit_q;
        // reload div-1, tick at 0: the period is EXACTLY div -
        // a +1 convention drifts one clock per bit and a UART's
        // peer keeps absolute time, unlike an SPI slave on edges
        tcnt_d = t_tick ? div_q - 16'd1 : tcnt_q - 16'd1;
        if (!ttip_q)
            txl_d = 1'b1;
        if (ttip_q && t_tick) begin
            if (tbit_q == t_end) begin
                ttip_d = 1'b0;
                txl_d  = 1'b1;
            end else begin
                tbit_d = tbit_q + 4'd1;
                if (tbit_q < 4'd8) begin
                    txl_d = tsh_q[0];
                    tsh_d = {1'b1, tsh_q[7:1]};
                end else if (pen && tbit_q == 4'd8)
                    txl_d = txp_q;
                else
                    txl_d = 1'b1;          // stop bit(s)
            end
        end
        if (tx_go) begin
            ttip_d = 1'b1;
            tsh_d  = tf_rdat;
            txp_d  = (^tf_rdat) ^ podd;    // even parity, or its inverse
            tbit_d = 4'd0;
            tcnt_d = div_q - 16'd1;
            txl_d  = 1'b0;                 // start bit, now
        end
    end

    zirh_tmr_reg #(.WIDTH(1))  u_ttip (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(ttip_d), .q_o(ttip_q), .err_o(e_ttip));
    zirh_tmr_reg #(.WIDTH(1))  u_txl  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(txl_d), .q_o(txl_q), .err_o(e_txl));
    zirh_tmr_reg #(.WIDTH(1))  u_txp  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(txp_d), .q_o(txp_q), .err_o(e_txp));
    zirh_tmr_reg #(.WIDTH(8))  u_tsh  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tsh_d), .q_o(tsh_q), .err_o(e_tsh));
    zirh_tmr_reg #(.WIDTH(4))  u_tbit (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tbit_d), .q_o(tbit_q), .err_o(e_tbit));
    zirh_tmr_reg #(.WIDTH(16)) u_tcnt (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tcnt_d), .q_o(tcnt_q), .err_o(e_tcnt));

    // ---------------------------------------------------------- RX engine
    // wait for the falling start edge, step to the start-bit CENTER
    // (half a bit), then sample eight data centers, the parity center
    // when enabled, and the stop
    wire        rbusy_q, rpe_q;
    wire [7:0]  rsh_q;
    wire [3:0]  rbit_q;
    wire [15:0] rcnt_q;
    reg         rbusy_d, rpe_d;
    reg  [7:0]  rsh_d;
    reg  [3:0]  rbit_d;
    reg  [15:0] rcnt_d;
    reg         rx_push, rx_ferr, rx_perr;
    wire e_rbusy, e_rpe, e_rsh, e_rbit, e_rcnt;

    wire r_tick = (rcnt_q == 16'd0);
    wire [3:0] r_stop = pen ? 4'd10 : 4'd9;

    always @* begin
        rbusy_d = rbusy_q;
        rpe_d   = rpe_q;
        rsh_d   = rsh_q;
        rbit_d  = rbit_q;
        rcnt_d  = rbusy_q ? (r_tick ? div_q - 16'd1 : rcnt_q - 16'd1) : 16'd0;
        rx_push = 1'b0;
        rx_ferr = 1'b0;
        rx_perr = 1'b0;

        if (!rbusy_q && en && !rx_in) begin
            rbusy_d = 1'b1;
            rbit_d  = 4'd0;
            rpe_d   = 1'b0;
            rcnt_d  = {1'b0, div_q[15:1]} - 16'd1;   // half a bit to center
        end

        if (rbusy_q && r_tick) begin
            if (rbit_q == 4'd0) begin
                if (rx_in)                     // false start
                    rbusy_d = 1'b0;
                else
                    rbit_d = 4'd1;
            end else if (rbit_q <= 4'd8) begin
                rsh_d  = {rx_in, rsh_q[7:1]};
                rbit_d = rbit_q + 4'd1;
            end else if (pen && rbit_q == 4'd9) begin
                rpe_d  = (rx_in != ((^rsh_q) ^ podd));
                rbit_d = rbit_q + 4'd1;
            end else begin                     // rbit_q == r_stop
                rbusy_d = 1'b0;
                if (!rx_in)
                    rx_ferr = 1'b1;            // broken stop: no byte
                else if (pen && rpe_q)
                    rx_perr = 1'b1;            // lying parity: no byte
                else
                    rx_push = 1'b1;            // honest frame: queue it
            end
        end
    end

    zirh_tmr_reg #(.WIDTH(1))  u_rbusy (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rbusy_d), .q_o(rbusy_q), .err_o(e_rbusy));
    zirh_tmr_reg #(.WIDTH(1))  u_rpe   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rpe_d), .q_o(rpe_q), .err_o(e_rpe));
    zirh_tmr_reg #(.WIDTH(8))  u_rsh   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rsh_d), .q_o(rsh_q), .err_o(e_rsh));
    zirh_tmr_reg #(.WIDTH(4))  u_rbit  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rbit_d), .q_o(rbit_q), .err_o(e_rbit));
    zirh_tmr_reg #(.WIDTH(16)) u_rcnt  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rcnt_d), .q_o(rcnt_q), .err_o(e_rcnt));

    // ------------------------------------------------------------- RX queue
    wire [7:0] rf_rdat;
    wire       rf_empty, rf_full, e_rf;
    wire [4:0] rf_level;
    zirh_fifo #(.WIDTH(8), .DEPTH_LOG2(4)) u_rxf (
        .clk(clk), .rst_n(rst_n),
        .wr_i(rx_push), .wdat_i(rsh_q),
        .rd_i(rd_fire & (reg_sel == 3'd3)), .rdat_o(rf_rdat),
        .empty_o(rf_empty), .full_o(rf_full), .level_o(rf_level),
        .err_o(e_rf));

    // ------------------------------------------------- sticky flags (W1C)
    // {perr, ferr, oe}: each set by its event, cleared by writing a 1
    // to its STAT bit; OE fires when an honest byte met a full queue
    wire [3:0] fl_q;
    reg  [3:0] fl_d;
    wire       e_fl;
    always @* begin
        fl_d = fl_q;
        if (wr_fire & (reg_sel == 3'd4))
            fl_d = fl_q & ~{1'b0, dat_i[6:4]};
        if (rx_push & rf_full) fl_d[0] = 1'b1;   // oe
        if (rx_ferr)           fl_d[1] = 1'b1;   // ferr
        if (rx_perr)           fl_d[2] = 1'b1;   // perr
    end
    zirh_tmr_reg #(.WIDTH(4)) u_fl (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(fl_d), .q_o(fl_q), .err_o(e_fl));

    assign tx_o     = txl_q;
    assign lease_o  = en;
    assign irq_rx_o = en & ~rf_empty;
    assign irq_tx_o = en & ~tf_full;

    assign rdt_o =
        (reg_sel == 3'd0) ? {28'h0, ctrl_q} :
        (reg_sel == 3'd1) ? {16'h0, div_q} :
        (reg_sel == 3'd2) ? {24'h0, tsh_q} :
        (reg_sel == 3'd3) ? {24'h0, rf_rdat} :
        {11'h0, tf_level, 3'h0, rf_level,
         1'b0, fl_q[2], fl_q[1], fl_q[0],
         rf_full, tf_full, ~rf_empty, ttip_q};

    assign ack_o = cyc_i;
    assign err_o = e_ctrl | e_div | e_tf | e_ttip | e_txl | e_txp | e_tsh
                 | e_tbit | e_tcnt | e_rbusy | e_rpe | e_rsh | e_rbit
                 | e_rcnt | e_rf | e_fl;

endmodule

`default_nettype wire
