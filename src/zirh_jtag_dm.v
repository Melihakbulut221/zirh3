// =============================================================================
// ZIRH-3 - JTAG debug transport + a compact RISC-V Debug Module (F27)
// src/zirh_jtag_dm.v
//
// The debug interface the brief asks for, built to sit BEHIND
// zirh_dbg_gate: a JTAG TAP speaks the RISC-V External Debug transport
// (DTM), and a minimal Debug Module turns dmcontrol writes into the
// halt/reset/bus-access requests the gate then permits or forces inert.
//
// Structure and the protection boundary:
//   * The TAP (IEEE 1149.1 16-state FSM) and the DTM shift registers
//     are a TRANSPORT - like the ISP UART receiver, they carry bits and
//     are deliberately NOT triplicated. A JTAG upset corrupts one
//     shifted word; the debugger re-issues it. Protection lives at the
//     boundary, which is the gate, not in the wire.
//   * The Debug Module's PERSISTENT control state (haltreq, ndmreset,
//     dmactive, the SBA control) is what actually reaches the system, so
//     it is TMR'd - and everything it produces is masked by
//     zirh_dbg_gate, which is latched locked at POR unless the flight
//     fuse permits debug. An open port is both an SEU path and a
//     security hole (the brief's F27 requirement); the gate is why this
//     module can exist on a flight die at all.
//
// DTM registers (addressed by the 5-bit IR):
//   0x01 IDCODE   - the standard read-only identifier
//   0x10 DTMCS    - transport status/control (version, abits, dmireset)
//   0x11 DMI      - {address[6:0], data[31:0], op[1:0]} the DM access
//   0x1f BYPASS   - one-bit passthrough
//
// DM registers (over DMI):
//   0x10 dmcontrol - haltreq[31], ndmreset[1], dmactive[0]
//   0x11 dmstatus  - allhalted/allrunning (from the core's halt ack)
//   0x38 sbcs      - system-bus-access control (sbreadonaddr, sbaccess)
//   0x39 sbaddress - the SBA address
//   0x3c sbdata0   - the SBA data (write triggers a bus write; a read
//                    after an address write triggers a bus read)
//
// The System Bus Access engine is the memory path a debugger uses to
// peek/poke without halting the core; here it drives the gate's
// dm_sba_* master, so even memory access is inert when locked.
// =============================================================================

`default_nettype none

module zirh_jtag_dm (
    // JTAG pins (TCK domain)
    input  wire        tck,
    input  wire        tms,
    input  wire        tdi,
    output reg         tdo,
    input  wire        trst_n,     // optional async TAP reset

    // system side
    input  wire        clk,
    input  wire        rst_n,

    // core halt acknowledge (from the SoC once it honours debug_req)
    input  wire        core_halted_i,

    // to zirh_dbg_gate (every one of these is masked when locked)
    output wire        dm_debug_req_o,
    output wire        dm_ndmreset_o,
    output wire        dm_sba_cyc_o,
    output wire [31:0] dm_sba_adr_o,
    output wire [31:0] dm_sba_dat_o,
    output wire        dm_sba_we_o,

    // SBA read return, from the gated bus
    input  wire [31:0] sba_rdt_i,
    input  wire        sba_ack_i,

    output wire        err_o        // DM control-state TMR mismatch
);

    localparam [31:0] IDCODE_VAL = 32'h5A3_00_001 ^ 32'h0;  // ZIRH-3 tap id

    // ---------------------------------------------------------------- TAP FSM
    // IEEE 1149.1 states encoded so tms drives the standard transitions.
    localparam [3:0]
        TEST_LOGIC_RESET = 4'h0, RUN_TEST_IDLE = 4'h1,
        SELECT_DR = 4'h2, CAPTURE_DR = 4'h3, SHIFT_DR = 4'h4,
        EXIT1_DR = 4'h5, PAUSE_DR = 4'h6, EXIT2_DR = 4'h7, UPDATE_DR = 4'h8,
        SELECT_IR = 4'h9, CAPTURE_IR = 4'hA, SHIFT_IR = 4'hB,
        EXIT1_IR = 4'hC, PAUSE_IR = 4'hD, EXIT2_IR = 4'hE, UPDATE_IR = 4'hF;

    reg [3:0] tap;
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) tap <= TEST_LOGIC_RESET;
        else case (tap)
            TEST_LOGIC_RESET: tap <= tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
            RUN_TEST_IDLE:    tap <= tms ? SELECT_DR        : RUN_TEST_IDLE;
            SELECT_DR:        tap <= tms ? SELECT_IR        : CAPTURE_DR;
            CAPTURE_DR:       tap <= tms ? EXIT1_DR         : SHIFT_DR;
            SHIFT_DR:         tap <= tms ? EXIT1_DR         : SHIFT_DR;
            EXIT1_DR:         tap <= tms ? UPDATE_DR        : PAUSE_DR;
            PAUSE_DR:         tap <= tms ? EXIT2_DR         : PAUSE_DR;
            EXIT2_DR:         tap <= tms ? UPDATE_DR        : SHIFT_DR;
            UPDATE_DR:        tap <= tms ? SELECT_DR        : RUN_TEST_IDLE;
            SELECT_IR:        tap <= tms ? TEST_LOGIC_RESET : CAPTURE_IR;
            CAPTURE_IR:       tap <= tms ? EXIT1_IR         : SHIFT_IR;
            SHIFT_IR:         tap <= tms ? EXIT1_IR         : SHIFT_IR;
            EXIT1_IR:         tap <= tms ? UPDATE_IR        : PAUSE_IR;
            PAUSE_IR:         tap <= tms ? EXIT2_IR         : PAUSE_IR;
            EXIT2_IR:         tap <= tms ? UPDATE_IR        : SHIFT_IR;
            UPDATE_IR:        tap <= tms ? SELECT_DR        : RUN_TEST_IDLE;
            default:          tap <= TEST_LOGIC_RESET;
        endcase
    end

    // ------------------------------------------------------------ IR + DR shift
    localparam [4:0] IR_IDCODE = 5'h01, IR_DTMCS = 5'h10,
                     IR_DMI = 5'h11, IR_BYPASS = 5'h1f;

    reg [4:0] ir;
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n)                     ir <= IR_IDCODE;
        else if (tap == TEST_LOGIC_RESET) ir <= IR_IDCODE;
        else if (tap == UPDATE_IR)        ir <= ir_shift;
    end

    reg [4:0] ir_shift;
    always @(posedge tck)
        if (tap == CAPTURE_IR)   ir_shift <= 5'b00001;    // fixed capture
        else if (tap == SHIFT_IR) ir_shift <= {tdi, ir_shift[4:1]};

    // DMI shift register: 7 address + 32 data + 2 op = 41 bits
    localparam integer DMIW = 41;
    reg [DMIW-1:0] dr;

    // captured DMI response for the next capture
    reg [33:0] dmi_resp;   // {data[31:0], op[1:0]} presented on CAPTURE

    always @(posedge tck) begin
        if (tap == CAPTURE_DR) begin
            case (ir)
                IR_IDCODE: dr <= {{(DMIW-32){1'b0}}, IDCODE_VAL};
                IR_DTMCS:  dr <= {{(DMIW-32){1'b0}}, dtmcs_val};
                IR_DMI:    dr <= {7'd0, dmi_resp};   // addr echo 0 + resp
                default:   dr <= {DMIW{1'b0}};       // bypass: 0
            endcase
        end else if (tap == SHIFT_DR) begin
            case (ir)
                IR_IDCODE, IR_DTMCS: dr <= {1'b0, tdi, dr[31:1]} & {DMIW{1'b1}};
                IR_DMI:    dr <= {tdi, dr[DMIW-1:1]};
                default:   dr <= {{(DMIW-1){1'b0}}, tdi};   // bypass 1 bit
            endcase
        end
    end

    // tdo: LSB of the active shift register, updated on the falling TCK edge
    always @(negedge tck) begin
        if (tap == SHIFT_IR)      tdo <= ir_shift[0];
        else if (tap == SHIFT_DR) tdo <= dr[0];
        else                      tdo <= 1'b0;
    end

    // DTMCS: version=1, abits=7, no error, dmireset self-clears
    wire [31:0] dtmcs_val = {14'd0, 7'd7 /*abits*/, 4'd0, 4'd1 /*version*/,
                             3'd0};

    // ------------------------------------------------- DMI update -> DM request
    // On UPDATE_DR with IR=DMI the low 41 bits hold {addr,data,op}; op=1
    // read, op=2 write. UPDATE_DR is a whole tck period (slower than clk),
    // so a LEVEL that is high across it survives a 2FF sync into the
    // system clock - cleaner than a tck-domain toggle, and free of the
    // non-blocking read race that a same-edge tap comparison suffers.
    wire dmi_update_lvl = (tap == UPDATE_DR) && (ir == IR_DMI);

    reg [2:0] upd_sync;
    always @(posedge clk)
        if (!rst_n) upd_sync <= 3'd0;
        else        upd_sync <= {upd_sync[1:0], dmi_update_lvl};
    wire dmi_stb = upd_sync[1] & ~upd_sync[2];   // one clk pulse per update

    // dr[40:0] is stable throughout UPDATE_DR, so sample it in clk on the
    // strobe rather than latching in the tck domain
    wire [6:0]  dmi_addr = dr[40:34];
    wire [31:0] dmi_data = dr[33:2];
    wire [1:0]  dmi_op   = dr[1:0];
    wire dmi_write = dmi_stb & (dmi_op == 2'd2);
    wire dmi_read  = dmi_stb & (dmi_op == 2'd1);

    // ------------------------------------------------- Debug Module (clk, TMR)
    localparam [6:0] A_DMCONTROL = 7'h10, A_DMSTATUS = 7'h11,
                     A_SBCS = 7'h38, A_SBADDRESS = 7'h39, A_SBDATA0 = 7'h3c;

    // dmcontrol: {haltreq, ndmreset, dmactive}, TMR'd
    wire        haltreq_q, ndmreset_q, dmactive_q;
    wire        e_hc, e_nr, e_da;
    wire dmc_wr = dmi_write & (dmi_addr == A_DMCONTROL);

    zirh_tmr_reg #(.WIDTH(1)) u_haltreq (.clk(clk), .rst_n(rst_n),
        .en_i(dmc_wr), .d_i(dmi_data[31]), .q_o(haltreq_q), .err_o(e_hc));
    zirh_tmr_reg #(.WIDTH(1)) u_ndmreset (.clk(clk), .rst_n(rst_n),
        .en_i(dmc_wr), .d_i(dmi_data[1]),  .q_o(ndmreset_q), .err_o(e_nr));
    zirh_tmr_reg #(.WIDTH(1)) u_dmactive (.clk(clk), .rst_n(rst_n),
        .en_i(dmc_wr), .d_i(dmi_data[0]),  .q_o(dmactive_q), .err_o(e_da));

    // SBA: address + data + a small handshake, control TMR'd
    wire [31:0] sbaddr_q, sbdata_q;
    wire        e_sa, e_sd, e_ss;
    wire sbaddr_wr = dmi_write & (dmi_addr == A_SBADDRESS);
    wire sbdata_wr = dmi_write & (dmi_addr == A_SBDATA0);
    wire sbcs_wr   = dmi_write & (dmi_addr == A_SBCS);

    // sbreadonaddr: a write to sbaddress launches a read; a write to
    // sbdata0 launches a write. Single outstanding access.
    wire        sbreadonaddr_q;
    zirh_tmr_reg #(.WIDTH(1)) u_sbroa (.clk(clk), .rst_n(rst_n),
        .en_i(sbcs_wr), .d_i(dmi_data[20]), .q_o(sbreadonaddr_q), .err_o(e_ss));

    reg  [31:0] sbaddr_d, sbdata_d;
    always @(*) begin
        sbaddr_d = sbaddr_q;  sbdata_d = sbdata_q;
        if (sbaddr_wr) sbaddr_d = dmi_data;
        if (sbdata_wr) sbdata_d = dmi_data;
        if (sba_ack_i & ~sb_we_q) sbdata_d = sba_rdt_i;  // capture read data
    end
    zirh_tmr_reg #(.WIDTH(32)) u_sbaddr (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(sbaddr_d), .q_o(sbaddr_q), .err_o(e_sa));
    zirh_tmr_reg #(.WIDTH(32)) u_sbdata (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(sbdata_d), .q_o(sbdata_q), .err_o(e_sd));

    // one-access SBA request state machine
    localparam [1:0] SB_IDLE = 2'd0, SB_REQ = 2'd1, SB_WAIT = 2'd2;
    wire [1:0] sb_st_q;  wire e_sb;
    reg  [1:0] sb_st_d;  reg sb_we_d;
    wire sb_we_q;  wire e_we;

    wire sb_launch_rd = sbaddr_wr & sbreadonaddr_q;
    wire sb_launch_wr = sbdata_wr;

    always @(*) begin
        sb_st_d = sb_st_q;  sb_we_d = sb_we_q;
        case (sb_st_q)
            SB_IDLE: if (sb_launch_wr) begin sb_st_d = SB_REQ; sb_we_d = 1'b1; end
                     else if (sb_launch_rd) begin sb_st_d = SB_REQ; sb_we_d = 1'b0; end
            SB_REQ:  sb_st_d = SB_WAIT;
            SB_WAIT: if (sba_ack_i) sb_st_d = SB_IDLE;
            default: sb_st_d = SB_IDLE;
        endcase
    end
    zirh_tmr_reg #(.WIDTH(2)) u_sbst (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(sb_st_d), .q_o(sb_st_q), .err_o(e_sb));
    zirh_tmr_reg #(.WIDTH(1)) u_sbwe (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(sb_we_d), .q_o(sb_we_q), .err_o(e_we));

    // ------------------------------------------------- DM outputs (to the gate)
    assign dm_debug_req_o = haltreq_q & dmactive_q;
    assign dm_ndmreset_o  = ndmreset_q & dmactive_q;
    assign dm_sba_cyc_o   = (sb_st_q == SB_REQ) | (sb_st_q == SB_WAIT);
    assign dm_sba_adr_o   = sbaddr_q;
    assign dm_sba_dat_o   = sbdata_q;
    assign dm_sba_we_o    = sb_we_q;

    // dmstatus read-back into the DMI response (allhalted from the core)
    always @(posedge clk) begin
        if (!rst_n) dmi_resp <= 34'd0;
        else if (dmi_read) begin
            case (dmi_addr)
                A_DMSTATUS:  dmi_resp <= {22'd0, core_halted_i, core_halted_i,
                                          8'd0, 2'd0};
                A_SBDATA0:   dmi_resp <= {sbdata_q, 2'd0};
                A_SBADDRESS: dmi_resp <= {sbaddr_q, 2'd0};
                default:     dmi_resp <= {30'd0, dmactive_q, ndmreset_q,
                                          haltreq_q, 2'd0};
            endcase
        end
    end

    assign err_o = e_hc | e_nr | e_da | e_sa | e_sd | e_ss | e_sb | e_we;

endmodule

`default_nettype wire
