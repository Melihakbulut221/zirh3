// ZIRH P2 - boot controller + SECDED SRAM glue for the cocotb suite
`default_nettype none
`timescale 1ns / 1ps

module tb_boot (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  strap_i,
    input  wire        st_valid_i,
    input  wire [7:0]  st_data_i,
    output wire        st_ready_o,
    input  wire        sig_ok_i,
    input  wire        signon_i,
    input  wire        wd_fail_i,
    output wire        boot_sel_o,
    output wire        bank_o,
    output wire        evt_accept_o,
    output wire        evt_reject_o,
    output wire        err_o
);
    wire        cyc, we, ack;
    wire [31:0] adr, dat, rdt;

    zirh_boot_ctrl #(.BANK_WORDS(512)) u_boot (
        .clk(clk), .rst_n(rst_n), .strap_i(strap_i),
        .st_valid_i(st_valid_i), .st_data_i(st_data_i),
        .st_ready_o(st_ready_o), .sig_ok_i(sig_ok_i),
        .signon_i(signon_i), .wd_fail_i(wd_fail_i),
        .m_cyc_o(cyc), .m_adr_o(adr), .m_dat_o(dat), .m_we_o(we),
        .m_rdt_i(rdt), .m_ack_i(ack),
        .boot_sel_o(boot_sel_o), .bank_o(bank_o),
        .evt_accept_o(evt_accept_o), .evt_reject_o(evt_reject_o),
        .err_o(err_o));

    wire sram_err;
    zirh_sram39 u_sram (
        .clk(clk), .rst_n(rst_n), .scrub_en_i(1'b0),
        .cyc_i(cyc), .adr_i(adr), .dat_i(dat), .sel_i(4'hF),
        .we_i(we), .rdt_o(rdt), .ack_o(ack),
        .evt_corr_o(), .evt_uncorr_o(), .evt_scrub_corr_o(),
        .err_o(sram_err),
        .bist_start_i(1'b0), .bist_mode_i(2'd0),
        .bist_busy_o(), .bist_pass_o(), .bist_fail_cnt_o(),
        .bist_fail_adr_o(), .bist_fail_map_o());

    wire _unused = &{sram_err, 1'b0};
endmodule

`default_nettype wire
