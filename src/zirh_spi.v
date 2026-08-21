// =============================================================================
// ZIRH-3 - SPI master (Cycle 32)
// src/zirh_spi.v
//
// One of the trio that closes the yardstick's SPI column. Full-duplex
// 8-bit master with all four CPOL/CPHA modes and SOFTWARE-OWNED chip
// select - flight software asserts CS, runs as many byte transfers as
// the device transaction needs, and releases it; no auto-CS guesses
// the protocol wrong. A TXD write launches the shift; MISO is sampled
// into the shift register and read back as RXD.
//
// Every register is TMR'd - control, divider, the shift register, the
// phase and bit counters - the same discipline the I2C pair set: a
// wedged peripheral FSM in flight is a lost instrument. Subset
// recorded honestly: master only, 8-bit words.
//
// Word map (one controller):
//   +0x00 CTRL {cs, cpha, cpol, en}   cs = drive the CS pin LOW
//   +0x04 DIV                          sck half-period, 16 bit
//   +0x08 TXD                          write launches the transfer
//   +0x0C RXD  (RO)
//   +0x10 STAT {tip}  (RO)
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
    output wire        cs_n_o,
    output wire        lease_o,

    output wire        err_o
);

    wire [2:0] reg_sel = adr_i[4:2];

    reg wr_seen;
    always @(posedge clk) begin
        if (!rst_n) wr_seen <= 1'b0;
        else        wr_seen <= cyc_i & we_i;
    end
    wire wr_fire = cyc_i & we_i & ~wr_seen;

    reg [1:0] miso_s;
    always @(posedge clk) miso_s <= {miso_s[0], miso_i};
    wire miso_in = miso_s[1];

    wire [3:0]  ctrl_q;
    wire [15:0] div_q;
    wire        e_ctrl, e_div;
    wire en   = ctrl_q[0];
    wire cpol = ctrl_q[1];
    wire cpha = ctrl_q[2];
    wire csr  = ctrl_q[3];

    zirh_tmr_reg #(.WIDTH(4)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd0)),
        .d_i(dat_i[3:0]), .q_o(ctrl_q), .err_o(e_ctrl));

    zirh_tmr_reg #(.WIDTH(16)) u_div (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd1)),
        .d_i(dat_i[15:0]), .q_o(div_q), .err_o(e_div));

    // ------------------------------------------------------------- engine
    // A transfer is 16 half-bits. sck toggles each half-bit; the
    // LEADING edge is the first toggle, the TRAILING the second.
    // CPHA 0: mosi valid before the leading edge, sample ON leading.
    // CPHA 1: mosi changes on leading, sample on trailing.
    wire        tip_q, sck_q, mosi_q;
    wire [7:0]  sh_q;
    wire [3:0]  hb_q;                  // half-bits remaining, 15..0
    wire [15:0] dcnt_q;
    reg         tip_d, sck_d, mosi_d;
    reg  [7:0]  sh_d;
    reg  [3:0]  hb_d;
    reg  [15:0] dcnt_d;
    wire e_tip, e_sck, e_sh, e_hb, e_dcnt, e_mosi;

    wire tick    = (dcnt_q == 16'd0);
    wire go      = wr_fire & (reg_sel == 3'd2) & en & ~tip_q;
    wire leading = (hb_q[0] == 1'b1);  // odd half-bits are leading edges

    always @* begin
        tip_d  = tip_q;
        sck_d  = sck_q;
        mosi_d = mosi_q;
        sh_d   = sh_q;
        hb_d   = hb_q;
        dcnt_d = tick ? div_q : dcnt_q - 16'd1;

        // the idle clock IS the polarity - a CPOL change between
        // transfers must reach the pin before the next arm
        if (!tip_q)
            sck_d = cpol;

        if (tip_q && tick) begin
            sck_d = ~sck_q;
            // sample on the edge software chose
            if (leading ? ~cpha : cpha)
                sh_d = {sh_q[6:0], miso_in};
            else
                // the NON-sampling edge advances MOSI - a wire that
                // moves on the sampling edge races every slave
                mosi_d = sh_q[7];
            if (hb_q == 4'd0) begin
                tip_d = 1'b0;
                sck_d = cpol;
            end else
                hb_d = hb_q - 4'd1;
        end

        if (go) begin
            tip_d  = 1'b1;
            sh_d   = dat_i[7:0];
            mosi_d = dat_i[7];
            hb_d   = 4'd15;
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
    zirh_tmr_reg #(.WIDTH(8))  u_sh   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sh_d), .q_o(sh_q), .err_o(e_sh));
    zirh_tmr_reg #(.WIDTH(4))  u_hb   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(hb_d), .q_o(hb_q), .err_o(e_hb));
    zirh_tmr_reg #(.WIDTH(16)) u_dcnt (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(dcnt_d), .q_o(dcnt_q), .err_o(e_dcnt));

    assign sck_o   = sck_q;
    assign mosi_o  = mosi_q;
    assign cs_n_o  = ~csr;
    assign lease_o = en;

    assign rdt_o =
        (reg_sel == 3'd0) ? {28'h0, ctrl_q} :
        (reg_sel == 3'd1) ? {16'h0, div_q} :
        (reg_sel == 3'd2) ? {24'h0, sh_q} :
        (reg_sel == 3'd3) ? {24'h0, sh_q} :
        {31'h0, tip_q};

    assign ack_o = cyc_i;
    assign err_o = e_ctrl | e_div | e_tip | e_sck | e_sh | e_hb | e_dcnt | e_mosi;

endmodule

`default_nettype wire
