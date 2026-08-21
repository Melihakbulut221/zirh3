// =============================================================================
// ZIRH-3 - SPI master (Cycle 32, deepened Cycle 36)
// src/zirh_spi.v
//
// One of the trio that closes the yardstick's SPI column. Full-duplex
// master with all four CPOL/CPHA modes and SOFTWARE-OWNED chip
// select - flight software asserts CS, runs as many word transfers as
// the device transaction needs, and releases it; no auto-CS guesses
// the protocol wrong. Cycle 36 gives it the yardstick's depth and
// width: sixteen-deep TMR'd FIFOs on both directions (a TXD write
// QUEUES and the engine drains on its own - exactly what a held CS
// and a deep queue are for), word lengths of 4 to 16 bits, and four
// decoded chip-select lines the same software owns through CSSEL.
//
// The laws, each carried over or earned:
//   - WLEN resets to 8 and CSSEL to 0: a program written against the
//     Cycle 32 block runs bit-identically.
//   - data is written and read RIGHT-ALIGNED; the wire is MSB-first
//     of the chosen length. The engine left-justifies internally so
//     the MSB always lives at the same flop.
//   - WLEN governs a word at its LAUNCH and is carried with it to
//     the end: the receive mask is LATCHED at go, so software may
//     reconfigure the length for the next word while this one is
//     still on the wire and the in-flight reply keeps every bit.
//   - a received word enters the RX queue unless the queue is full -
//     then it is DROPPED and OE goes sticky (W1C through STAT), the
//     UART's law: the oldest data survives.
//   - the extra chip selects only reach pins when MCS is set; with it
//     clear the block drives exactly the one pin it always drove.
//   - the MISO listener is double-synchronized (two clocks of lag),
//     so full-duplex READS need a half-bit longer than that lag:
//     DIV of 3 or more. Writes fly at any DIV; a DIV-2 read returns
//     every reply one bit stale - measured, not guessed.
//
// Word map (one controller):
//   +0x00 CTRL {mcs, cssel[1:0], cs, cpha, cpol, en}  cs = SELECTED line LOW
//   +0x04 DIV                          sck half-period, 16 bit
//   +0x08 TXD  write pushes the TX queue (refused when full)
//   +0x0C RXD  (RO) read pops the RX queue
//   +0x10 STAT {tx_lvl[20:16], rx_lvl[12:8], oe[4],
//               rx_full[3], tx_full[2], rx_valid[1], tip[0]}  oe W1C
//   +0x14 WLEN word length in bits, 4..16 (resets to 8)
// =============================================================================

`default_nettype none

module zirh_spi (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave (sub-decoded window)
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // pin side (push-pull when leased; MISO listens)
    output wire        sck_o,
    output wire        mosi_o,
    input  wire        miso_i,
    output wire [3:0]  cs_n_o,       // decoded; [0] is the classic pin
    output wire        lease_o,
    output wire        mcs_lease_o,  // the extra selects reach pins only here
    output wire        rdy_o,

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

    reg [1:0] miso_s;
    always @(posedge clk) miso_s <= {miso_s[0], miso_i};
    wire miso_in = miso_s[1];

    wire [6:0]  ctrl_q;
    wire [15:0] div_q;
    wire [4:0]  wlen_q;
    wire        e_ctrl, e_div, e_wlen;
    wire        en    = ctrl_q[0];
    wire        cpol  = ctrl_q[1];
    wire        cpha  = ctrl_q[2];
    wire        csr   = ctrl_q[3];
    wire [1:0]  cssel = ctrl_q[5:4];
    wire        mcs   = ctrl_q[6];

    zirh_tmr_reg #(.WIDTH(7)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd0)),
        .d_i(dat_i[6:0]), .q_o(ctrl_q), .err_o(e_ctrl));

    zirh_tmr_reg #(.WIDTH(16)) u_div (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd1)),
        .d_i(dat_i[15:0]), .q_o(div_q), .err_o(e_div));

    zirh_tmr_reg #(.WIDTH(5), .RESET_VALUE(5'd8)) u_wlen (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd5)),
        .d_i(dat_i[4:0]), .q_o(wlen_q), .err_o(e_wlen));

    // ------------------------------------------------------------- TX queue
    wire [15:0] tf_rdat;
    wire        tf_empty, tf_full, e_tf;
    wire [4:0]  tf_level;
    wire        go;
    zirh_fifo #(.WIDTH(16), .DEPTH_LOG2(4)) u_txf (
        .clk(clk), .rst_n(rst_n),
        .wr_i(wr_fire & (reg_sel == 3'd2) & en),
        .wdat_i(dat_i[15:0]),
        .rd_i(go), .rdat_o(tf_rdat),
        .empty_o(tf_empty), .full_o(tf_full), .level_o(tf_level),
        .err_o(e_tf));

    // ------------------------------------------------------------- engine
    // A transfer is 2*wlen half-bits. sck toggles each half-bit; the
    // LEADING edge is the first toggle, the TRAILING the second.
    // CPHA 0: mosi valid before the leading edge, sample ON leading.
    // CPHA 1: mosi changes on leading, sample on trailing.
    wire        tip_q, sck_q, mosi_q;
    wire [15:0] sh_q, msk_q;
    wire [4:0]  hb_q;                  // half-bits remaining
    wire [15:0] dcnt_q;
    reg         tip_d, sck_d, mosi_d;
    reg  [15:0] sh_d, msk_d;
    reg  [4:0]  hb_d;
    reg  [15:0] dcnt_d;
    reg         rx_push;
    wire e_tip, e_sck, e_sh, e_hb, e_dcnt, e_mosi, e_msk;

    wire tick    = (dcnt_q == 16'd0);
    assign go    = en & ~tip_q & ~tf_empty;
    wire leading = (hb_q[0] == 1'b1);  // odd half-bits are leading edges

    // left-justify at launch so the word's MSB always sits at sh[15];
    // the received word accumulates right-aligned through the same
    // register - full duplex on one set of flops
    wire [4:0]  lshift  = 5'd16 - wlen_q;
    wire [15:0] tx_word = tf_rdat << lshift;
    wire [15:0] rx_mask = ~(16'hFFFF << wlen_q);

    always @* begin
        tip_d   = tip_q;
        sck_d   = sck_q;
        mosi_d  = mosi_q;
        sh_d    = sh_q;
        msk_d   = msk_q;
        hb_d    = hb_q;
        dcnt_d  = tick ? div_q : dcnt_q - 16'd1;
        rx_push = 1'b0;

        // the idle clock IS the polarity - a CPOL change between
        // transfers must reach the pin before the next arm
        if (!tip_q)
            sck_d = cpol;

        if (tip_q && tick) begin
            sck_d = ~sck_q;
            // sample on the edge software chose
            if (leading ? ~cpha : cpha)
                sh_d = {sh_q[14:0], miso_in};
            else
                // the NON-sampling edge advances MOSI - a wire that
                // moves on the sampling edge races every slave
                mosi_d = sh_q[15];
            if (hb_q == 5'd0) begin
                tip_d   = 1'b0;
                sck_d   = cpol;
                rx_push = 1'b1;        // the finished word queues
            end else
                hb_d = hb_q - 5'd1;
        end

        if (go) begin
            tip_d  = 1'b1;
            sh_d   = tx_word;
            mosi_d = tx_word[15];
            // {wlen[3:0],0} is 2*wlen mod 32; minus one lands on
            // 2*wlen-1 for every legal length INCLUDING 16 (0-1 wraps
            // to 31, which is exactly 2*16-1)
            hb_d   = {wlen_q[3:0], 1'b0} - 5'd1;
            msk_d  = rx_mask;          // the length travels WITH the word
            dcnt_d = div_q;
            sck_d  = cpol;
        end
    end

    zirh_tmr_reg #(.WIDTH(1))  u_tip  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tip_d), .q_o(tip_q), .err_o(e_tip));
    zirh_tmr_reg #(.WIDTH(1))  u_sck  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sck_d), .q_o(sck_q), .err_o(e_sck));
    zirh_tmr_reg #(.WIDTH(1))  u_mosi (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(mosi_d), .q_o(mosi_q), .err_o(e_mosi));
    zirh_tmr_reg #(.WIDTH(16)) u_sh   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sh_d), .q_o(sh_q), .err_o(e_sh));
    zirh_tmr_reg #(.WIDTH(5))  u_hb   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(hb_d), .q_o(hb_q), .err_o(e_hb));
    zirh_tmr_reg #(.WIDTH(16)) u_dcnt (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(dcnt_d), .q_o(dcnt_q), .err_o(e_dcnt));
    zirh_tmr_reg #(.WIDTH(16)) u_msk  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(msk_d), .q_o(msk_q), .err_o(e_msk));

    // ------------------------------------------------------------- RX queue
    wire [15:0] rf_rdat;
    wire        rf_empty, rf_full, e_rf;
    wire [4:0]  rf_level;
    // the push rides the FINAL edge, and with CPHA=1 that edge is
    // itself a sampling edge - the queue must take the register's
    // NEXT value (sh_d), which carries the just-sampled last bit;
    // with CPHA=0 the last sample came an edge earlier and sh_d
    // equals sh_q there, so both phases queue the whole word
    zirh_fifo #(.WIDTH(16), .DEPTH_LOG2(4)) u_rxf (
        .clk(clk), .rst_n(rst_n),
        .wr_i(rx_push), .wdat_i(sh_d & msk_q),
        .rd_i(rd_fire & (reg_sel == 3'd3)), .rdat_o(rf_rdat),
        .empty_o(rf_empty), .full_o(rf_full), .level_o(rf_level),
        .err_o(e_rf));

    // ------------------------------------------------- sticky flag (W1C)
    wire fl_q;
    reg  fl_d;
    wire e_fl;
    always @* begin
        fl_d = fl_q;
        if (wr_fire & (reg_sel == 3'd4))
            fl_d = fl_q & ~dat_i[4];
        if (rx_push & rf_full) fl_d = 1'b1;      // oe: a word was LOST
    end
    zirh_tmr_reg #(.WIDTH(1)) u_fl (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(fl_d), .q_o(fl_q), .err_o(e_fl));

    // one decoded select; software still owns WHEN it is low
    wire [3:0] cs_dec = csr ? (4'b0001 << cssel) : 4'b0000;
    assign cs_n_o      = ~cs_dec;
    assign sck_o       = sck_q;
    assign mosi_o      = mosi_q;
    assign lease_o     = en;
    assign mcs_lease_o = en & mcs;
    assign rdy_o       = en & ~tf_full;

    assign rdt_o =
        (reg_sel == 3'd0) ? {25'h0, ctrl_q} :
        (reg_sel == 3'd1) ? {16'h0, div_q} :
        (reg_sel == 3'd2) ? {16'h0, sh_q} :
        (reg_sel == 3'd3) ? {16'h0, rf_rdat} :
        (reg_sel == 3'd5) ? {27'h0, wlen_q} :
        {11'h0, tf_level, 3'h0, rf_level,
         3'b000, fl_q, rf_full, tf_full, ~rf_empty, tip_q};

    assign ack_o = cyc_i;
    assign err_o = e_ctrl | e_div | e_wlen | e_tf | e_tip | e_sck | e_sh
                 | e_hb | e_dcnt | e_mosi | e_msk | e_rf | e_fl;

endmodule

`default_nettype wire
