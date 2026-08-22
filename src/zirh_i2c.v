// =============================================================================
// ZIRH-3 - I2C master + slave (Cycles 31, 37)
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
// fought. Cycle 37 adds the OTHER chair at the same two pins: a
// slave engine behind SADR that answers its seven-bit address,
// queues written bytes sixteen deep and serves reads from its own
// queue. The slave never stretches SCL (this die shifts at 50 MHz
// against a kilohertz bus); its backpressure is the protocol's own -
// a byte arriving to a full queue is NACKed, not dropped, and a read
// from an empty queue serves all-ones with UE sticky. Master and
// slave are EXCLUSIVE chairs: enabling the slave address parks the
// master's command door.
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
//   +0x14 STAT {stretch_to, rxack, tip}   rxack = 1 means slave NACKed;
//         stretch_to is sticky and write-1-to-clear - the leg was
//         ABANDONED because the slave held SCL past the limit
//   +0x18 SADR {en, addr[6:0]}          slave chair; en parks the master
//   +0x1C SSTAT {tx_lvl[20:16], rx_lvl[12:8],
//                ue[5], rx_full[3], tx_full[2],
//                rx_valid[1], busy[0]}   ue W1C; a full RX queue
//                NACKs on the wire, so there is no OE to flag
//   +0x20 SRXD (RO) read pops the slave RX queue
//   +0x24 STXD write pushes the slave TX queue
// =============================================================================

`default_nettype none

module zirh_i2c #(
    // quarter-bit ticks a slave may hold the clock before the master
    // gives up on the leg. Generous by default - a real device may
    // stretch for milliseconds - but FINITE, which is the whole point:
    // a bus that never lets go must not take the controller with it.
    parameter integer STRETCH_LOG2 = 12
) (
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
    output wire        rdy_o,         // enabled and idle: feed me

    output wire        err_o
);

    localparam [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_BITS = 3'd2,
                     S_ACK  = 3'd3, S_STOP  = 3'd4;

    wire [3:0] reg_sel = adr_i[5:2];

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
        .en_i(wr_fire & (reg_sel == 4'd0)),
        .d_i(dat_i[0]), .q_o(ctrl_q), .err_o(e_ctrl));

    zirh_tmr_reg #(.WIDTH(16)) u_div (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 4'd1)),
        .d_i(dat_i[15:0]), .q_o(div_q), .err_o(e_div));

    wire cmd_fire = wr_fire & (reg_sel == 4'd2) & ctrl_q & ~sl_en;
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
        .en_i(wr_fire & (reg_sel == 4'd3)),
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
    wire [2:0]  fl_q;                  // {stretch_to, rxack, tip}
    wire        sdo_q;                 // sda value the engine presents
    reg  [2:0]  st_d;
    reg  [1:0]  ph_d;
    reg  [3:0]  bit_d;
    reg  [15:0] dcnt_d;
    reg  [7:0]  sh_d;
    reg  [2:0]  fl_d;
    reg         sdo_d;
    wire e_st, e_ph, e_bit, e_dcnt, e_sh, e_fl, e_sdo, e_sto;
    // how long the current stretch has lasted, in quarter-bit ticks
    wire [STRETCH_LOG2-1:0] sto_q;
    reg  [STRETCH_LOG2-1:0] sto_d;

    wire tick   = (dcnt_q == 16'd0);
    wire ph_hi  = ph_q[1];             // phases 2,3: clock released

    always @* begin
        st_d   = st_q;
        ph_d   = ph_q;
        bit_d  = bit_q;
        sh_d   = sh_q;
        fl_d   = fl_q;
        sdo_d  = sdo_q;
        sto_d  = sto_q;
        dcnt_d = tick ? div_q : dcnt_q - 16'd1;

        // phase 2 waits for the RELEASED clock to actually rise
        if (st_q != S_IDLE && tick) begin
            if (ph_q == 2'd2 && !scl_in) begin
                dcnt_d = div_q;                     // stretched: wait
                sto_d  = sto_q + {{(STRETCH_LOG2-1){1'b0}}, 1'b1};
                if (&sto_q) begin
                    // the slave has held the clock past the limit. Let
                    // the leg go: release the wire, drop tip so software
                    // can command again, and SAY so in a sticky flag.
                    // Waiting forever is not patience, it is a hang.
                    st_d    = S_IDLE;
                    fl_d[0] = 1'b0;
                    fl_d[2] = 1'b1;
                    sdo_d   = 1'b1;
                    sto_d   = {STRETCH_LOG2{1'b0}};
                end
            end else begin
                sto_d = {STRETCH_LOG2{1'b0}};
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

        // STAT is write-1-to-clear for the sticky stretch verdict
        if (wr_fire & (reg_sel == 4'd5))
            fl_d[2] = fl_q[2] & ~dat_i[2];

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

        // a controller that is switched off - or parked behind the
        // slave chair - is IDLE. Leaving the engine frozen mid-leg
        // meant a re-enable resumed a transaction the bus had long
        // forgotten, and gave software no way out of a wedge at all.
        if (!ctrl_q || sl_en) begin
            st_d    = S_IDLE;
            ph_d    = 2'd0;
            fl_d[0] = 1'b0;
            sdo_d   = 1'b1;
            sto_d   = {STRETCH_LOG2{1'b0}};
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
    zirh_tmr_reg #(.WIDTH(3))  u_fl   (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(fl_d), .q_o(fl_q), .err_o(e_fl));
    zirh_tmr_reg #(.WIDTH(STRETCH_LOG2)) u_sto (
        .clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sto_d), .q_o(sto_q), .err_o(e_sto));
    zirh_tmr_reg #(.WIDTH(1))  u_sdo  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sdo_d), .q_o(sdo_q), .err_o(e_sdo));

    // ------------------------------------------------- the slave chair
    wire [7:0] sadr_q;
    wire       e_sadr;
    zirh_tmr_reg #(.WIDTH(8)) u_sadr (
        .clk(clk), .rst_n(rst_n),
        .en_i(wr_fire & (reg_sel == 4'd6)),
        .d_i(dat_i[7:0]), .q_o(sadr_q), .err_o(e_sadr));
    wire       sl_en   = sadr_q[7];
    wire [6:0] sl_addr = sadr_q[6:0];

    wire [7:0] stf_rdat, srf_rdat;
    wire       stf_empty, stf_full, srf_empty, srf_full, e_stf, e_srf;
    wire [4:0] stf_level, srf_level;
    reg        sl_tx_pop, sl_rx_push;
    reg  [7:0] srx_dat;
    zirh_fifo #(.WIDTH(8), .DEPTH_LOG2(4)) u_stxf (
        .clk(clk), .rst_n(rst_n),
        .wr_i(wr_fire & (reg_sel == 4'd9) & sl_en),
        .wdat_i(dat_i[7:0]),
        .rd_i(sl_tx_pop), .rdat_o(stf_rdat),
        .empty_o(stf_empty), .full_o(stf_full), .level_o(stf_level),
        .err_o(e_stf));
    zirh_fifo #(.WIDTH(8), .DEPTH_LOG2(4)) u_srxf (
        .clk(clk), .rst_n(rst_n),
        .wr_i(sl_rx_push), .wdat_i(srx_dat),
        .rd_i(rd_fire & (reg_sel == 4'd8)), .rdat_o(srf_rdat),
        .empty_o(srf_empty), .full_o(srf_full), .level_o(srf_level),
        .err_o(e_srf));

    // bus condition detectors on the synced wires
    reg scl_p, sda_p;
    always @(posedge clk) begin
        scl_p <= scl_in;
        sda_p <= sda_in;
    end
    wire scl_rise = scl_in & ~scl_p;
    wire scl_fall = ~scl_in & scl_p;
    wire sda_fall = ~sda_in & sda_p;
    wire sda_rise = sda_in & ~sda_p;
    wire bus_start = sl_en & scl_in & sda_fall;    // START/repeated START
    wire bus_stop  = sl_en & scl_in & sda_rise;    // STOP

    // the engine: shift on SCL rises, present on SCL falls, pull SDA
    // only for ACKs and zero data bits - open drain, never high
    localparam [2:0] SL_IDLE = 3'd0, SL_ADDR = 3'd1, SL_AACK = 3'd2,
                     SL_WRX  = 3'd3, SL_WACK = 3'd4, SL_RTX  = 3'd5,
                     SL_RACK = 3'd6;
    wire [2:0] sst_q;
    wire [7:0] ssh_q;
    wire [3:0] sbit_q;
    wire [2:0] sfl_q;                  // {ue, spare, busy}
    wire       ssda_q;                 // 1 = release, 0 = pull
    reg  [2:0] sst_d;
    reg  [7:0] ssh_d;
    reg  [3:0] sbit_d;
    reg  [2:0] sfl_d;
    reg        ssda_d;
    wire e_sst, e_ssh, e_sbit, e_sfl, e_ssda;

    always @* begin
        sst_d      = sst_q;
        ssh_d      = ssh_q;
        sbit_d     = sbit_q;
        sfl_d      = sfl_q;
        ssda_d     = ssda_q;
        sl_tx_pop  = 1'b0;
        sl_rx_push = 1'b0;
        srx_dat    = ssh_q;

        if (wr_fire & (reg_sel == 4'd7))
            sfl_d[2:1] = sfl_q[2:1] & ~dat_i[5:4];

        if (bus_stop || !sl_en) begin
            sst_d    = SL_IDLE;
            sfl_d[0] = 1'b0;
            ssda_d   = 1'b1;
        end else if (bus_start) begin
            sst_d    = SL_ADDR;            // covers repeated START too
            sbit_d   = 4'd0;
            sfl_d[0] = 1'b1;
            ssda_d   = 1'b1;
        end else case (sst_q)
            SL_ADDR: if (scl_rise) begin
                ssh_d  = {ssh_q[6:0], sda_in};
                sbit_d = sbit_q + 4'd1;
            end else if (scl_fall && sbit_q == 4'd8) begin
                if (ssh_q[7:1] == sl_addr) begin
                    sst_d  = SL_AACK;
                    ssda_d = 1'b0;         // ACK the address
                end else
                    sst_d = SL_IDLE;       // not ours: stay silent
            end
            SL_AACK: if (scl_fall) begin
                sbit_d = 4'd0;
                if (ssh_q[0]) begin        // master READS us
                    sst_d = SL_RTX;
                    if (stf_empty) begin
                        ssh_d    = 8'hFF;  // starving: all-ones
                        sfl_d[2] = 1'b1;   // ue sticky
                    end else begin
                        ssh_d     = stf_rdat;
                        sl_tx_pop = 1'b1;
                    end
                    ssda_d = stf_empty ? 1'b1 : stf_rdat[7];
                end else begin             // master WRITES us
                    sst_d  = SL_WRX;
                    ssda_d = 1'b1;
                end
            end
            SL_WRX: if (scl_rise) begin
                ssh_d  = {ssh_q[6:0], sda_in};
                sbit_d = sbit_q + 4'd1;
            end else if (scl_fall && sbit_q == 4'd8) begin
                sst_d = SL_WACK;
                // the protocol's own backpressure: a full queue
                // NACKs the byte instead of losing it
                if (!srf_full) begin
                    sl_rx_push = 1'b1;
                    ssda_d     = 1'b0;     // ACK
                end else
                    ssda_d = 1'b1;         // NACK: try again later
            end
            SL_WACK: if (scl_fall) begin
                sst_d  = SL_WRX;
                sbit_d = 4'd0;
                ssda_d = 1'b1;
            end
            SL_RTX: begin
                if (scl_fall) begin
                    if (sbit_q == 4'd7) begin
                        sst_d  = SL_RACK;
                        ssda_d = 1'b1;     // release for master's verdict
                    end else begin
                        sbit_d = sbit_q + 4'd1;
                        ssda_d = ssh_q[6]; // next bit onto the wire
                        ssh_d  = {ssh_q[6:0], 1'b1};
                    end
                end
            end
            SL_RACK: begin
                if (scl_rise) begin
                    // master ACK (low) wants more; NACK ends the read
                    if (sda_in)
                        sst_d = SL_IDLE;
                end else if (scl_fall) begin
                    sbit_d = 4'd0;
                    sst_d  = SL_RTX;
                    if (stf_empty) begin
                        ssh_d    = 8'hFF;
                        sfl_d[2] = 1'b1;
                    end else begin
                        ssh_d     = stf_rdat;
                        sl_tx_pop = 1'b1;
                    end
                    ssda_d = stf_empty ? 1'b1 : stf_rdat[7];
                end
            end
            default: ;
        endcase
    end

    zirh_tmr_reg #(.WIDTH(3)) u_sst  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sst_d), .q_o(sst_q), .err_o(e_sst));
    zirh_tmr_reg #(.WIDTH(8)) u_ssh  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(ssh_d), .q_o(ssh_q), .err_o(e_ssh));
    zirh_tmr_reg #(.WIDTH(4)) u_sbit (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sbit_d), .q_o(sbit_q), .err_o(e_sbit));
    zirh_tmr_reg #(.WIDTH(3)) u_sfl  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sfl_d), .q_o(sfl_q), .err_o(e_sfl));
    zirh_tmr_reg #(.WIDTH(1), .RESET_VALUE(1'b1)) u_ssda (
        .clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(ssda_d), .q_o(ssda_q), .err_o(e_ssda));

    // START holds scl high while sda falls; everything else follows
    // the phase. Open drain: pull only ever means LOW.
    wire scl_release = (st_q == S_IDLE) | (st_q == S_START) | ph_hi;
    // the slave never touches SCL; both chairs share the SDA pull
    assign scl_pull_o = ctrl_q & ~sl_en & ~scl_release;
    assign sda_pull_o = (ctrl_q & ~sl_en & (st_q != S_IDLE) & ~sdo_q)
                      | (sl_en & ~ssda_q);
    assign lease_o    = ctrl_q | sl_en;
    assign rdy_o      = ctrl_q & ~sl_en & ~fl_q[0];

    assign rdt_o =
        (reg_sel == 4'd0) ? {31'h0, ctrl_q} :
        (reg_sel == 4'd1) ? {16'h0, div_q} :
        (reg_sel == 4'd2) ? {27'h0, cmd_q} :
        (reg_sel == 4'd3) ? {24'h0, txd_q} :
        (reg_sel == 4'd4) ? {24'h0, sh_q} :
        (reg_sel == 4'd6) ? {24'h0, sadr_q} :
        (reg_sel == 4'd7) ? {11'h0, stf_level, 3'h0, srf_level,
                             2'b00, sfl_q[2], 1'b0,
                             srf_full, stf_full, ~srf_empty, sfl_q[0]} :
        (reg_sel == 4'd8) ? {24'h0, srf_rdat} :
        (reg_sel == 4'd5) ? {29'h0, fl_q} :
        {29'h0, fl_q};

    assign ack_o = cyc_i;
    assign err_o = e_ctrl | e_div | e_cmd | e_txd | e_st | e_ph
                 | e_bit | e_dcnt | e_sh | e_fl | e_sdo | e_sto
                 | e_sadr | e_stf | e_srf | e_sst | e_ssh
                 | e_sbit | e_sfl | e_ssda;

endmodule

`default_nettype wire
