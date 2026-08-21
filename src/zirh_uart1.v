// =============================================================================
// ZIRH-3 - the second UART (Cycle 33)
// src/zirh_uart1.v
//
// The last column of the yardstick's interface ledger. UART0 is the
// die's lifeline - console, telemetry and ISP share it on dedicated
// pins at the reset-strapped rate. This one is the PAYLOAD's serial
// port: a plain programmable 8N1 endpoint on PORTA alternate
// functions, baud set by software, owned by software, nothing else
// riding it.
//
// Every register is TMR'd - control, divisor, both engines' shift
// registers and counters - the peripheral discipline this die
// settled on three blocks ago. Reading RXD clears the valid flag;
// a byte arriving over a byte not yet read simply replaces it and
// the software's rate discipline is the flow control, exactly like
// every small flight UART.
//
// Word map:
//   +0x00 CTRL {en}          enable leases PORTA 16 (TX) / 17 (RX)
//   +0x04 DIV                bit period in clk cycles, 16 bit
//   +0x08 TXD                write launches a frame when idle
//   +0x0C RXD  (RO)          reading clears rx_valid
//   +0x10 STAT {rx_valid, tip}
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
    output wire        irq_tx_o,      // the transmitter is free,

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

    wire        ctrl_q;
    wire [15:0] div_q;
    wire        e_ctrl, e_div;
    zirh_tmr_reg #(.WIDTH(1)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd0)),
        .d_i(dat_i[0]), .q_o(ctrl_q), .err_o(e_ctrl));
    zirh_tmr_reg #(.WIDTH(16)) u_div (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd1)),
        .d_i(dat_i[15:0]), .q_o(div_q), .err_o(e_div));

    // ---------------------------------------------------------- TX engine
    // frame = start(0), d0..d7 lsb first, stop(1); tx idles high
    wire        ttip_q, txl_q;
    wire [7:0]  tsh_q;
    wire [3:0]  tbit_q;
    wire [15:0] tcnt_q;
    reg         ttip_d, txl_d;
    reg  [7:0]  tsh_d;
    reg  [3:0]  tbit_d;
    reg  [15:0] tcnt_d;
    wire e_ttip, e_txl, e_tsh, e_tbit, e_tcnt;

    wire tx_go   = wr_fire & (reg_sel == 3'd2) & ctrl_q & ~ttip_q;
    wire t_tick  = (tcnt_q == 16'd0);

    always @* begin
        ttip_d = ttip_q;
        txl_d  = txl_q;
        tsh_d  = tsh_q;
        tbit_d = tbit_q;
        // reload div-1, tick at 0: the period is EXACTLY div -
        // a +1 convention drifts one clock per bit and a UART's
        // peer keeps absolute time, unlike an SPI slave on edges
        tcnt_d = t_tick ? div_q - 16'd1 : tcnt_q - 16'd1;
        if (!ttip_q)
            txl_d = 1'b1;
        if (ttip_q && t_tick) begin
            if (tbit_q == 4'd9) begin
                ttip_d = 1'b0;
                txl_d  = 1'b1;
            end else begin
                tbit_d = tbit_q + 4'd1;
                if (tbit_q < 4'd8) begin
                    txl_d = tsh_q[0];
                    tsh_d = {1'b1, tsh_q[7:1]};
                end else
                    txl_d = 1'b1;          // stop bit
            end
        end
        if (tx_go) begin
            ttip_d = 1'b1;
            tsh_d  = dat_i[7:0];
            tbit_d = 4'd0;
            tcnt_d = div_q - 16'd1;
            txl_d  = 1'b0;                 // start bit, now
        end
    end

    zirh_tmr_reg #(.WIDTH(1))  u_ttip (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(ttip_d), .q_o(ttip_q), .err_o(e_ttip));
    zirh_tmr_reg #(.WIDTH(1))  u_txl  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(txl_d), .q_o(txl_q), .err_o(e_txl));
    zirh_tmr_reg #(.WIDTH(8))  u_tsh  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tsh_d), .q_o(tsh_q), .err_o(e_tsh));
    zirh_tmr_reg #(.WIDTH(4))  u_tbit (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tbit_d), .q_o(tbit_q), .err_o(e_tbit));
    zirh_tmr_reg #(.WIDTH(16)) u_tcnt (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tcnt_d), .q_o(tcnt_q), .err_o(e_tcnt));

    // ---------------------------------------------------------- RX engine
    // wait for the falling start edge, step to the start-bit CENTER
    // (half a bit), then sample eight data centers and the stop
    wire        rbusy_q, rvld_q;
    wire [7:0]  rsh_q, rxd_q;
    wire [3:0]  rbit_q;
    wire [15:0] rcnt_q;
    reg         rbusy_d, rvld_d;
    reg  [7:0]  rsh_d, rxd_d;
    reg  [3:0]  rbit_d;
    reg  [15:0] rcnt_d;
    wire e_rbusy, e_rvld, e_rsh, e_rxd, e_rbit, e_rcnt;

    wire r_tick = (rcnt_q == 16'd0);

    always @* begin
        rbusy_d = rbusy_q;
        rvld_d  = rvld_q;
        rsh_d   = rsh_q;
        rxd_d   = rxd_q;
        rbit_d  = rbit_q;
        rcnt_d  = rbusy_q ? (r_tick ? div_q - 16'd1 : rcnt_q - 16'd1) : 16'd0;

        if (!rbusy_q && ctrl_q && !rx_in) begin
            rbusy_d = 1'b1;
            rbit_d  = 4'd0;
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
            end else begin
                rbusy_d = 1'b0;
                if (rx_in) begin               // stop bit honest
                    rxd_d  = rsh_q;
                    rvld_d = 1'b1;
                end
            end
        end

        if (rd_fire & (reg_sel == 3'd3))
            rvld_d = 1'b0;
    end

    zirh_tmr_reg #(.WIDTH(1))  u_rbusy (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rbusy_d), .q_o(rbusy_q), .err_o(e_rbusy));
    zirh_tmr_reg #(.WIDTH(1))  u_rvld  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rvld_d), .q_o(rvld_q), .err_o(e_rvld));
    zirh_tmr_reg #(.WIDTH(8))  u_rsh   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rsh_d), .q_o(rsh_q), .err_o(e_rsh));
    zirh_tmr_reg #(.WIDTH(8))  u_rxd   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rxd_d), .q_o(rxd_q), .err_o(e_rxd));
    zirh_tmr_reg #(.WIDTH(4))  u_rbit  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rbit_d), .q_o(rbit_q), .err_o(e_rbit));
    zirh_tmr_reg #(.WIDTH(16)) u_rcnt  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(rcnt_d), .q_o(rcnt_q), .err_o(e_rcnt));

    assign tx_o     = txl_q;
    assign lease_o  = ctrl_q;
    assign irq_rx_o = ctrl_q & rvld_q;
    assign irq_tx_o = ctrl_q & ~ttip_q;

    assign rdt_o =
        (reg_sel == 3'd0) ? {31'h0, ctrl_q} :
        (reg_sel == 3'd1) ? {16'h0, div_q} :
        (reg_sel == 3'd2) ? {24'h0, tsh_q} :
        (reg_sel == 3'd3) ? {24'h0, rxd_q} :
        {30'h0, rvld_q, ttip_q};

    assign ack_o = cyc_i;
    assign err_o = e_ctrl | e_div | e_ttip | e_txl | e_tsh | e_tbit | e_tcnt
                 | e_rbusy | e_rvld | e_rsh | e_rxd | e_rbit | e_rcnt;

endmodule

`default_nettype wire
