// =============================================================================
// ZIRH-3 - I2C master (Cycle 31)
// src/zirh_i2c.v
//
// One of the pair that closes the yardstick's I2C column. A byte
// command engine in the classic shape: software writes CMD with some
// of {STA, STO, RD, WR, NACK} set and the engine runs one bus
// transaction leg - start, one byte out or in, the acknowledge, stop
// - while TIP says busy. Open-drain discipline throughout: the
// controller only ever pulls low (scl_pull/sda_pull), reads the wire
// as it actually is, and after RELEASING the clock it waits for SCL
// to really rise - a slave stretching the clock is obeyed, not
// fought. Slave mode is deliberately out of scope (recorded, like
// the timer bank's missing cascade); flight use is commanding
// sensors, and a master that tolerates stretching covers it.
//
// Every register is TMR'd - control, divider, command latch, the
// shift register, the FSM state and its counters - because a wedged
// peripheral FSM in flight is a lost instrument; faults land in
// err_o like everything on this die.
//
// Word map (one controller):
//   +0x00 CTRL {en}          enable also LEASES the two PORTA pins
//   +0x04 DIV                quarter-bit time in clk cycles, 16 bit
//   +0x08 CMD  {NACK,RD,WR,STO,STA}   write starts the leg
//   +0x0C TXD
//   +0x10 RXD  (RO)
//   +0x14 STAT {rxack, tip}  (RO; rxack = 1 means slave NACKed)
// =============================================================================

`default_nettype none

module zirh_i2c (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave (sub-decoded window)
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // open-drain pin side: pull means drive low, never drive high
    input  wire        scl_i,
    output wire        scl_pull_o,
    input  wire        sda_i,
    output wire        sda_pull_o,
    output wire        lease_o,       // en: the pins belong to this block

    output wire        err_o
);

    localparam [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_BITS = 3'd2,
                     S_ACK  = 3'd3, S_STOP  = 3'd4;

    wire [2:0] reg_sel = adr_i[4:2];

    reg wr_seen;
    always @(posedge clk) begin
        if (!rst_n) wr_seen <= 1'b0;
        else        wr_seen <= cyc_i & we_i;
    end
    wire wr_fire = cyc_i & we_i & ~wr_seen;

    // pin synchronizers (the wire as it actually is)
    reg [1:0] scl_s, sda_s;
    always @(posedge clk) begin
        scl_s <= {scl_s[0], scl_i};
        sda_s <= {sda_s[0], sda_i};
    end
    wire scl_in = scl_s[1];
    wire sda_in = sda_s[1];

    wire        ctrl_q;
    wire [15:0] div_q;
    wire [4:0]  cmd_q;
    wire [7:0]  txd_q;
    wire        e_ctrl, e_div, e_cmd, e_txd;

    zirh_tmr_reg #(.WIDTH(1)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd0)),
        .d_i(dat_i[0]), .q_o(ctrl_q), .err_o(e_ctrl));

    zirh_tmr_reg #(.WIDTH(16)) u_div (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd1)),
        .d_i(dat_i[15:0]), .q_o(div_q), .err_o(e_div));

    wire cmd_fire = wr_fire & (reg_sel == 3'd2) & ctrl_q;
    zirh_tmr_reg #(.WIDTH(5)) u_cmd (
        .clk(clk), .rst_n(rst_n),
        .en_i(cmd_fire),
        .d_i(dat_i[4:0]), .q_o(cmd_q), .err_o(e_cmd));
    wire c_sta  = cmd_q[0];
    wire c_sto  = cmd_q[1];
    wire c_wr   = cmd_q[2];
    wire c_rd   = cmd_q[3];
    wire c_nack = cmd_q[4];

    zirh_tmr_reg #(.WIDTH(8)) u_txd (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 3'd3)),
        .d_i(dat_i[7:0]), .q_o(txd_q), .err_o(e_txd));

    // ------------------------------------------------------------- engine
    // quarter-bit phasing: 0 = scl low, sda set; 1 = scl low, hold;
    // 2 = scl released (wait for the WIRE to rise: stretch obeyed),
    // sample on entry to 3; 3 = scl high, hold; back to 0.
    wire [2:0]  st_q;
    wire [1:0]  ph_q;
    wire [3:0]  bit_q;
    wire [15:0] dcnt_q;
    wire [7:0]  sh_q;
    wire [1:0]  fl_q;                  // {rxack, tip}
    wire        sdo_q;                 // sda value the engine presents
    reg  [2:0]  st_d;
    reg  [1:0]  ph_d;
    reg  [3:0]  bit_d;
    reg  [15:0] dcnt_d;
    reg  [7:0]  sh_d;
    reg  [1:0]  fl_d;
    reg         sdo_d;
    wire e_st, e_ph, e_bit, e_dcnt, e_sh, e_fl, e_sdo;

    wire tick   = (dcnt_q == 16'd0);
    wire ph_hi  = ph_q[1];             // phases 2,3: clock released

    always @* begin
        st_d   = st_q;
        ph_d   = ph_q;
        bit_d  = bit_q;
        sh_d   = sh_q;
        fl_d   = fl_q;
        sdo_d  = sdo_q;
        dcnt_d = tick ? div_q : dcnt_q - 16'd1;

        // phase 2 waits for the RELEASED clock to actually rise
        if (st_q != S_IDLE && tick) begin
            if (ph_q == 2'd2 && !scl_in)
                dcnt_d = div_q;                     // stretched: wait
            else begin
                ph_d = ph_q + 2'd1;                 // wraps 3 -> 0
                if (ph_q == 2'd2) begin             // sampling edge
                    if (st_q == S_BITS && c_rd)
                        sh_d = {sh_q[6:0], sda_in};
                    if (st_q == S_ACK && !c_rd)
                        fl_d[1] = sda_in;           // rxack from slave
                end
                if (ph_q == 2'd3) begin             // bit boundary
                    case (st_q)
                        S_START: begin
                            st_d  = S_BITS;
                            bit_d = 4'd7;
                            sdo_d = c_wr ? txd_q[7] : 1'b1;
                        end
                        S_BITS: begin
                            if (bit_q == 4'd0) begin
                                st_d  = S_ACK;
                                // writer releases sda for the slave's
                                // ack; reader drives its own answer
                                sdo_d = c_rd ? c_nack : 1'b1;
                            end else begin
                                bit_d = bit_q - 4'd1;
                                sdo_d = c_wr ? txd_q[bit_q - 4'd1] : 1'b1;
                            end
                        end
                        S_ACK: begin
                            if (c_sto) begin
                                st_d  = S_STOP;
                                sdo_d = 1'b0;       // stop needs sda low
                            end else begin
                                st_d    = S_IDLE;
                                fl_d[0] = 1'b0;     // leg done
                            end
                        end
                        S_STOP: begin
                            st_d    = S_IDLE;
                            fl_d[0] = 1'b0;
                            sdo_d   = 1'b1;
                        end
                        default: ;
                    endcase
                end
            end
        end

        // command acceptance: from idle, one leg per CMD write
        if (cmd_fire && st_q == S_IDLE) begin
            fl_d[0] = 1'b1;                         // tip
            ph_d    = 2'd0;
            dcnt_d  = div_q;
            if (dat_i[0]) begin                     // STA
                st_d  = S_START;
                sdo_d = 1'b0;                       // sda falls, scl high
            end else begin
                st_d  = S_BITS;
                bit_d = 4'd7;
                sdo_d = dat_i[2] ? txd_q[7] : 1'b1;
            end
        end
    end

    zirh_tmr_reg #(.WIDTH(3))  u_st   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(st_d), .q_o(st_q), .err_o(e_st));
    zirh_tmr_reg #(.WIDTH(2))  u_ph   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(ph_d), .q_o(ph_q), .err_o(e_ph));
    zirh_tmr_reg #(.WIDTH(4))  u_bit  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(bit_d), .q_o(bit_q), .err_o(e_bit));
    zirh_tmr_reg #(.WIDTH(16)) u_dcnt (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(dcnt_d), .q_o(dcnt_q), .err_o(e_dcnt));
    zirh_tmr_reg #(.WIDTH(8))  u_sh   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sh_d), .q_o(sh_q), .err_o(e_sh));
    zirh_tmr_reg #(.WIDTH(2))  u_fl   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(fl_d), .q_o(fl_q), .err_o(e_fl));
    zirh_tmr_reg #(.WIDTH(1))  u_sdo  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sdo_d), .q_o(sdo_q), .err_o(e_sdo));

    // START holds scl high while sda falls; everything else follows
    // the phase. Open drain: pull only ever means LOW.
    wire scl_release = (st_q == S_IDLE) | (st_q == S_START) | ph_hi;
    assign scl_pull_o = ctrl_q & ~scl_release;
    assign sda_pull_o = ctrl_q & (st_q != S_IDLE) & ~sdo_q;
    assign lease_o    = ctrl_q;

    assign rdt_o =
        (reg_sel == 3'd0) ? {31'h0, ctrl_q} :
        (reg_sel == 3'd1) ? {16'h0, div_q} :
        (reg_sel == 3'd2) ? {27'h0, cmd_q} :
        (reg_sel == 3'd3) ? {24'h0, txd_q} :
        (reg_sel == 3'd4) ? {24'h0, sh_q} :
        {30'h0, fl_q};

    assign ack_o = cyc_i;
    assign err_o = e_ctrl | e_div | e_cmd | e_txd | e_st | e_ph
                 | e_bit | e_dcnt | e_sh | e_fl | e_sdo;

endmodule

`default_nettype wire
