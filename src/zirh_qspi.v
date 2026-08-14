// =============================================================================
// ZIRH product program P2 - QSPI-MRAM read controller
// zirh_qspi.v
//
// PROGRAM.md A5, the chip-side leg: firmware lives in external
// rad-tolerant MRAM; this controller streams it out over SPI mode 0
// as the byte stream zirh_boot_ctrl consumes - the transport-agnostic
// boot design pays off here, the two blocks meet at valid/ready and
// nothing else.
//
//   x1  standard READ (0x03): command, 24-bit address, data on IO1
//   x4  QUAD OUTPUT READ (0x6B): command and address on IO0, DUMMY
//       cycles (parameter, part-dependent), nibbles on IO[3:0]
//
// Flow control is the consumer's: when st_ready drops mid-transfer,
// SCK freezes with CS held low - SPI permits a paused clock, and the
// stream resumes exactly where it stopped. Abort (or the TMR trap)
// releases CS immediately: a mangled controller must let go of the
// bus, never hold it hostage.
//
// The protection boundary (docs/PROGRAM.md A5): the MRAM cell is
// SEU-immune, this controller and the wires are not - hence full TMR
// on state and counters, the safe-state trap, and the image-level
// CRC + signature that zirh_boot_ctrl verifies on what was STORED.
// Sector-level CRC for the in-flight updater is protocol layered
// above both blocks (docs/BOOT.md), not duplicated here.
// =============================================================================

`default_nettype none

module zirh_qspi #(
    parameter integer SCK_DIV_LOG2 = 1,   // sck = clk / 2^(N+1)
    parameter integer QUAD_DUMMY   = 8    // dummy sck cycles after 0x6B addr
) (
    input  wire        clk,
    input  wire        rst_n,

    // command interface
    input  wire        start_i,
    input  wire        quad_i,          // 0: x1 READ, 1: x4 quad-output
    input  wire [23:0] addr_i,
    input  wire [23:0] len_i,           // bytes to stream
    input  wire        abort_i,
    output wire        busy_o,

    // byte stream toward zirh_boot_ctrl
    output wire        st_valid_o,
    output wire [7:0]  st_data_o,
    input  wire        st_ready_i,

    // pads
    output wire        sck_o,
    output wire        cs_n_o,
    output wire [3:0]  io_o,
    output wire [3:0]  io_oe,
    input  wire [3:0]  io_i,

    output wire        err_o
);

    localparam [7:0] CMD_READ = 8'h03, CMD_QOR = 8'h6B;

    // --- states -------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_CMD = 3'd1, S_ADDR = 3'd2,
                     S_DUMMY = 3'd3, S_DATA = 3'd4, S_EMIT = 3'd5;

    wire [2:0]  st_q;   reg [2:0]  st_d;
    wire [4:0]  bit_q;  reg [4:0]  bit_d;   // bits/nibbles left in phase
    wire [23:0] len_q;  reg [23:0] len_d;
    wire [23:0] adr_q;  reg [23:0] adr_d;
    wire [7:0]  sh_q;   reg [7:0]  sh_d;    // shift register
    wire        qm_q;   reg        qm_d;    // quad mode latched at start
    wire [SCK_DIV_LOG2:0] div_q;
    reg  [SCK_DIV_LOG2:0] div_d;
    wire        sck_q;  reg        sck_d;   // sck level

    wire e0, e1, e2, e3, e4, e5, e6, e7;
    zirh_tmr_reg #(.WIDTH(3))  u_st  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(st_d),  .q_o(st_q),  .err_o(e0));
    zirh_tmr_reg #(.WIDTH(5))  u_bit (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(bit_d), .q_o(bit_q), .err_o(e1));
    zirh_tmr_reg #(.WIDTH(24)) u_len (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(len_d), .q_o(len_q), .err_o(e2));
    zirh_tmr_reg #(.WIDTH(24)) u_adr (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(adr_d), .q_o(adr_q), .err_o(e3));
    zirh_tmr_reg #(.WIDTH(8))  u_sh  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sh_d),  .q_o(sh_q),  .err_o(e4));
    zirh_tmr_reg #(.WIDTH(1))  u_qm  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(qm_d),  .q_o(qm_q),  .err_o(e5));
    zirh_tmr_reg #(.WIDTH(SCK_DIV_LOG2+1)) u_div (.clk(clk), .rst_n(rst_n),
        .en_i(1'b1), .d_i(div_d), .q_o(div_q), .err_o(e6));
    zirh_tmr_reg #(.WIDTH(1))  u_sck (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sck_d), .q_o(sck_q), .err_o(e7));

    assign err_o = e0 | e1 | e2 | e3 | e4 | e5 | e6 | e7;

    // --- sck generation: ticks gate every phase advance ---------------------
    // the divider only runs while a transfer is active and the consumer
    // is not stalling a data byte; a stall freezes sck mid-low (mode 0)
    wire active  = (st_q != S_IDLE) & (st_q != S_EMIT);
    wire stalled = 1'b0;   // EMIT state carries the stall; sck idles there
    wire run     = active & ~stalled;

    wire tick_hi = run & (div_q == {(SCK_DIV_LOG2+1){1'b1}}) & ~sck_q;
    wire tick_lo = run & (div_q == {(SCK_DIV_LOG2+1){1'b1}}) &  sck_q;

    assign sck_o  = sck_q;
    assign cs_n_o = (st_q == S_IDLE);
    assign busy_o = (st_q != S_IDLE);

    // --- IO lanes -----------------------------------------------------------
    // command and address always go out on IO0; x1 data arrives on IO1,
    // x4 data on IO[3:0]. Outputs change on falling sck (mode 0 master),
    // inputs sample on rising sck.
    assign io_o  = {3'b000, sh_q[7]};
    assign io_oe = (st_q == S_CMD || st_q == S_ADDR) ? 4'b0001 : 4'b0000;

    // --- byte emission ------------------------------------------------------
    reg [7:0] emit_q;
    reg       emit_v;
    assign st_valid_o = emit_v;
    assign st_data_o  = emit_q;

    // --- next state ---------------------------------------------------------
    always @* begin
        st_d  = st_q;   bit_d = bit_q;  len_d = len_q;
        adr_d = adr_q;  sh_d  = sh_q;   qm_d  = qm_q;
        div_d = div_q + 1'b1;
        sck_d = sck_q;

        if (!run) div_d = {(SCK_DIV_LOG2+1){1'b0}};
        if (tick_hi) sck_d = 1'b1;
        if (tick_lo) sck_d = 1'b0;

        case (st_q)
            S_IDLE: begin
                sck_d = 1'b0;
                if (start_i) begin
                    qm_d  = quad_i;
                    sh_d  = quad_i ? CMD_QOR : CMD_READ;
                    bit_d = 5'd8;
                    len_d = len_i;
                    adr_d = addr_i;
                    st_d  = S_CMD;
                end
            end

            // shift out on falling edges: after a full sck period the
            // slave has sampled the bit on the rising edge
            S_CMD: begin
                if (tick_lo) begin
                    sh_d  = {sh_q[6:0], 1'b0};
                    bit_d = bit_q - 5'd1;
                    if (bit_q == 5'd1) begin
                        sh_d  = adr_q[23:16];
                        bit_d = 5'd24;
                        st_d  = S_ADDR;
                    end
                end
            end

            S_ADDR: begin
                if (tick_lo) begin
                    bit_d = bit_q - 5'd1;
                    sh_d  = {sh_q[6:0], 1'b0};
                    if (bit_q == 5'd17) sh_d = adr_q[15:8];
                    if (bit_q == 5'd9)  sh_d = adr_q[7:0];
                    if (bit_q == 5'd1) begin
                        bit_d = qm_q ? QUAD_DUMMY[4:0] : 5'd8;
                        sh_d  = 8'h00;
                        st_d  = qm_q ? S_DUMMY : S_DATA;
                    end
                end
            end

            S_DUMMY: begin
                if (tick_lo) begin
                    bit_d = bit_q - 5'd1;
                    if (bit_q == 5'd1) begin
                        bit_d = 5'd2;          // 2 nibbles per byte
                        st_d  = S_DATA;
                    end
                end
            end

            // sample on rising edges; x1 collects 8 bits, x4 two nibbles
            S_DATA: begin
                if (tick_hi) begin
                    if (qm_q) begin
                        sh_d  = {sh_q[3:0], io_i};
                        bit_d = bit_q - 5'd1;
                        if (bit_q == 5'd1) st_d = S_EMIT;
                    end else begin
                        sh_d  = {sh_q[6:0], io_i[1]};
                        bit_d = bit_q - 5'd1;
                        if (bit_q == 5'd1) st_d = S_EMIT;
                    end
                end
            end

            // hand the byte to the consumer; sck idles low here, CS
            // stays asserted - the pause IS the flow control
            S_EMIT: begin
                sck_d = 1'b0;
                if (st_ready_i) begin
                    len_d = len_q - 24'd1;
                    bit_d = qm_q ? 5'd2 : 5'd8;
                    if (len_q == 24'd1) st_d = S_IDLE;
                    else                st_d = S_DATA;
                end
            end

            default: st_d = S_IDLE;   // trap: release the bus
        endcase

        if (abort_i) st_d = S_IDLE;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            emit_v <= 1'b0;
            emit_q <= 8'h00;
        end else begin
            if (st_q == S_DATA && st_d == S_EMIT)
                emit_q <= qm_q ? {sh_q[3:0], io_i} : {sh_q[6:0], io_i[1]};
            emit_v <= (st_d == S_EMIT);
        end
    end

    `include "zirh_assert.vh"
    // the bus is released the instant the controller is not mid-frame,
    // and a stream byte is only ever offered while CS is asserted
    `ZIRH_ASSERT(a_state_legal, st_q <= S_EMIT)
    `ZIRH_ASSERT(a_cs_when_idle, (st_q != S_IDLE) || cs_n_o)
    `ZIRH_ASSERT(a_valid_needs_cs, !st_valid_o || !cs_n_o || (st_q == S_IDLE))

endmodule

`default_nettype wire
