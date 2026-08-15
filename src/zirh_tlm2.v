// =============================================================================
// ZIRH-2 - telemetry framer v2
// zirh_tlm2.v
//
// Same architecture as zirh_tlm (atomic snapshot, TMR'd interval and frame
// state, plain checksum-covered payload), wider frame. v1 stays untouched
// for the frozen ZIRH-1.
//
// FRAME v2.1 (20 bytes):
//   0  0x5A 'Z'    1  0x33 '3'   <- length is keyed off this marker
//   2  STATUS      {seq[3:0], armed, infra, mode[1:0]}
//   3-4   PLAIN    5-6   RAW_A   7-8   ESC_A     (16-bit big-endian)
//   9-10  RAW_B    11-12 ESC_B
//   13 ECC_CORR    14 ECC_UNCORR
//   15 CPU_SIG     <- firmware's rolling liveness signature
//   16 BOOT        <- CPU watchdog reboots: a climbing value means the
//                     computer keeps dying and keeps being recovered
//   17 BUS_TO      18 RX_FERR
//   19 XOR of bytes 0..18
//
// ESC_A versus ESC_B side by side in every frame IS the placement A/B
// experiment's data product; CPU_SIG frozen across frames means the
// computer died while the instrument kept reporting - exactly the failure
// separation ZIRH-2 exists to demonstrate.
// =============================================================================

`default_nettype none

module zirh_tlm2 #(
    parameter integer INTERVAL_LOG2 = 16
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] cnt_plain_i,
    input  wire [15:0] cnt_raw_a_i,
    input  wire [15:0] cnt_esc_a_i,
    input  wire [15:0] cnt_raw_b_i,
    input  wire [15:0] cnt_esc_b_i,
    input  wire [7:0]  cnt_ecc_c_i,
    input  wire [7:0]  cnt_ecc_u_i,
    input  wire [7:0]  cpu_sig_i,
    input  wire [7:0]  boot_cnt_i,
    input  wire [7:0]  cnt_bus_to_i,
    input  wire [7:0]  cnt_ferr_i,
    input  wire        armed_i,
    input  wire [1:0]  mode_i,
    input  wire        err_infra_i,

    output wire [7:0]  tx_data_o,
    output wire        tx_valid_o,
    input  wire        tx_ready_i,

    output wire        err_o
);

    localparam integer IW = INTERVAL_LOG2;
    localparam [4:0] LAST_IDX = 5'd19;

    wire [IW-1:0] intv_q;
    wire          intv_err;
    wire          fire = (intv_q == {IW{1'b0}});

    zirh_tmr_reg #(.WIDTH(IW), .RESET_VALUE({IW{1'b1}})) u_intv (
        .clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(fire ? {IW{1'b1}} : intv_q - {{(IW-1){1'b0}}, 1'b1}),
        .q_o(intv_q), .err_o(intv_err));

    wire [5:0] st_q;
    wire       st_err;
    wire       busy = st_q[5];
    wire [4:0] idx  = st_q[4:0];

    wire start = fire & ~busy;
    wire adv   = busy & tx_ready_i;
    wire done  = adv & (idx >= LAST_IDX);

    wire [5:0] st_nxt = start ? 6'b1_00000 :
                        done  ? 6'b0_00000 :
                                {1'b1, idx + 5'd1};

    zirh_tmr_reg #(.WIDTH(6)) u_st (
        .clk(clk), .rst_n(rst_n), .en_i(start | adv),
        .d_i(st_nxt), .q_o(st_q), .err_o(st_err));

    // --- snapshot -----------------------------------------------------------
    reg [15:0] s_plain, s_raw_a, s_esc_a, s_raw_b, s_esc_b;
    reg [7:0]  s_ecc_c, s_ecc_u, s_sig, s_boot, s_busto, s_ferr;
    reg        s_armed, s_infra;
    reg [1:0]  s_mode;
    reg [3:0]  seq;
    reg        infra_sticky;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_plain <= 16'h0; s_raw_a <= 16'h0; s_esc_a <= 16'h0;
            s_raw_b <= 16'h0; s_esc_b <= 16'h0;
            s_ecc_c <= 8'h0;  s_ecc_u <= 8'h0;  s_sig <= 8'h0;
            s_boot <= 8'h0;   s_busto <= 8'h0;  s_ferr <= 8'h0;
            s_armed <= 1'b0;  s_infra <= 1'b0;  s_mode <= 2'b00;
            seq <= 4'h0; infra_sticky <= 1'b0;
        end else begin
            infra_sticky <= start ? 1'b0 : (infra_sticky | err_infra_i);
            if (start) begin
                s_plain <= cnt_plain_i;  s_raw_a <= cnt_raw_a_i;
                s_esc_a <= cnt_esc_a_i;  s_raw_b <= cnt_raw_b_i;
                s_esc_b <= cnt_esc_b_i;
                s_ecc_c <= cnt_ecc_c_i;  s_ecc_u <= cnt_ecc_u_i;
                s_sig   <= cpu_sig_i;
                s_boot  <= boot_cnt_i;
                s_busto <= cnt_bus_to_i;
                s_ferr  <= cnt_ferr_i;
                s_armed <= armed_i;
                s_infra <= infra_sticky | err_infra_i;
                s_mode  <= mode_i;
                seq     <= seq + 4'd1;
            end
        end
    end

    wire [7:0] status = {seq, s_armed, s_infra, s_mode};

    reg [7:0] chk;
    reg [7:0] byte_mux;
    always @(*) begin
        case (idx)
            5'd0:    byte_mux = 8'h5A;
            5'd1:    byte_mux = 8'h33;
            5'd2:    byte_mux = status;
            5'd3:    byte_mux = s_plain[15:8];
            5'd4:    byte_mux = s_plain[7:0];
            5'd5:    byte_mux = s_raw_a[15:8];
            5'd6:    byte_mux = s_raw_a[7:0];
            5'd7:    byte_mux = s_esc_a[15:8];
            5'd8:    byte_mux = s_esc_a[7:0];
            5'd9:    byte_mux = s_raw_b[15:8];
            5'd10:   byte_mux = s_raw_b[7:0];
            5'd11:   byte_mux = s_esc_b[15:8];
            5'd12:   byte_mux = s_esc_b[7:0];
            5'd13:   byte_mux = s_ecc_c;
            5'd14:   byte_mux = s_ecc_u;
            5'd15:   byte_mux = s_sig;
            5'd16:   byte_mux = s_boot;
            5'd17:   byte_mux = s_busto;
            5'd18:   byte_mux = s_ferr;
            default: byte_mux = chk;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n)     chk <= 8'h00;
        else if (start) chk <= 8'h00;
        else if (adv && idx < LAST_IDX) chk <= chk ^ byte_mux;
    end

    assign tx_data_o  = byte_mux;
    assign tx_valid_o = busy;
    assign err_o      = intv_err | st_err;

endmodule

`default_nettype wire
