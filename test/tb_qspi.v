// ZIRH P2 - QSPI controller + behavioral SPI-MRAM + the full boot path
`default_nettype none
`timescale 1ns / 1ps

// mode-0 SPI/QSPI MRAM: READ 0x03 (x1) and QUAD OUTPUT 0x6B (x4, 8 dummy)
module tb_mram (
    input  wire       sck,
    input  wire       cs_n,
    input  wire [3:0] io_o,     // from master
    output reg  [3:0] io_i      // to master
);
    reg [7:0] mem [0:65535];
    reg [7:0]  cmd;
    reg [23:0] adr;
    reg [5:0]  n;
    reg [2:0]  phase;   // 0 cmd 1 addr 2 dummy 3 data
    reg [7:0]  dout;
    reg        nib;

    always @(negedge cs_n) begin
        phase <= 0; n <= 0; cmd <= 0; nib <= 0;
    end

    // sample master bits on rising sck
    always @(posedge sck) begin
        if (!cs_n) case (phase)
            0: begin
                cmd <= {cmd[6:0], io_o[0]};
                n <= n + 1;
                if (n == 7) begin phase <= 1; n <= 0; end
            end
            1: begin
                adr <= {adr[22:0], io_o[0]};
                n <= n + 1;
                if (n == 23) begin
                    n <= 0; nib <= 0;
                    phase <= ({cmd[6:0], io_o[0]} == 8'h6B
                              || cmd == 8'h6B) ? 2 : 3;
                    if (cmd[6:0] == 7'h35 || {cmd[6:0],io_o[0]} == 8'h6B)
                        ;
                end
            end
            2: begin
                n <= n + 1;
                if (n == 7) begin phase <= 3; n <= 0; end
            end
            default: ;
        endcase
    end

    // drive read data on falling sck (master samples next rising)
    always @(negedge sck) begin
        if (!cs_n && phase == 3) begin
            if (cmd == 8'h03) begin
                if (n == 0) begin
                    dout <= mem[adr[15:0]];
                    io_i[1] <= mem[adr[15:0]][7];
                end else
                    io_i[1] <= dout[7 - n[2:0]];
                n <= (n == 7) ? 0 : n + 1;
                if (n == 7) adr <= adr + 1;
            end else begin  // 0x6B quad
                if (!nib) begin
                    io_i <= mem[adr[15:0]][7:4];
                    dout <= mem[adr[15:0]];
                    nib  <= 1;
                end else begin
                    io_i <= dout[3:0];
                    nib  <= 0;
                    adr  <= adr + 1;
                end
            end
        end
    end
endmodule

module tb_qspi (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_i,
    input  wire        quad_i,
    input  wire [23:0] addr_i,
    input  wire [23:0] len_i,
    input  wire        abort_i,
    output wire        busy_o,
    // raw-tap mode: observe the stream directly
    input  wire        tap_ready_i,
    output wire        tap_valid_o,
    output wire [7:0]  tap_data_o,
    // boot mode: route the stream into the boot controller
    input  wire        use_boot_i,
    input  wire [1:0]  strap_i,
    output wire        boot_sel_o,
    output wire        bank_o,
    output wire        evt_accept_o,
    output wire        evt_reject_o
);
    wire sck, cs_n;
    wire [3:0] io_m2s, io_s2m, io_oe;

    wire st_v; wire [7:0] st_d; wire st_r;

    zirh_qspi u_qspi (
        .clk(clk), .rst_n(rst_n),
        .start_i(start_i), .quad_i(quad_i), .addr_i(addr_i),
        .len_i(len_i), .abort_i(abort_i), .busy_o(busy_o),
        .st_valid_o(st_v), .st_data_o(st_d), .st_ready_i(st_r),
        .sck_o(sck), .cs_n_o(cs_n),
        .io_o(io_m2s), .io_oe(io_oe), .io_i(io_s2m),
        .err_o());

    tb_mram u_mram (.sck(sck), .cs_n(cs_n), .io_o(io_m2s), .io_i(io_s2m));

    // stream routing
    wire b_ready;
    assign st_r        = use_boot_i ? b_ready : tap_ready_i;
    assign tap_valid_o = use_boot_i ? 1'b0 : st_v;
    assign tap_data_o  = st_d;

    // boot + SECDED SRAM (the full A5 path)
    wire cyc, we, ack;
    wire [31:0] adr, dat, rdt;
    zirh_boot_ctrl #(.BANK_WORDS(512)) u_boot (
        .clk(clk), .rst_n(rst_n), .strap_i(strap_i),
        .st_valid_i(st_v & use_boot_i), .st_data_i(st_d),
        .st_ready_o(b_ready), .sig_ok_i(1'b1),
        .signon_i(1'b0), .wd_fail_i(1'b0),
        .m_cyc_o(cyc), .m_adr_o(adr), .m_dat_o(dat), .m_we_o(we),
        .m_rdt_i(rdt), .m_ack_i(ack),
        .boot_sel_o(boot_sel_o), .bank_o(bank_o),
        .evt_accept_o(evt_accept_o), .evt_reject_o(evt_reject_o),
        .err_o());

    zirh_sram39 u_sram (
        .clk(clk), .rst_n(rst_n), .scrub_en_i(1'b0),
        .cyc_i(cyc), .adr_i(adr), .dat_i(dat), .sel_i(4'hF),
        .we_i(we), .rdt_o(rdt), .ack_o(ack),
        .evt_corr_o(), .evt_uncorr_o(), .evt_scrub_corr_o(), .err_o(),
        .bist_start_i(1'b0), .bist_mode_i(2'd0),
        .bist_busy_o(), .bist_pass_o(), .bist_fail_cnt_o(),
        .bist_fail_adr_o(), .bist_fail_map_o());

    wire _unused = &{io_oe, 1'b0};
endmodule

`default_nettype wire
