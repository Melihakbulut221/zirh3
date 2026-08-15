// =============================================================================
// ZIRH-3 - the CPU-carrying top (SoC-import ladder, rung 3)
// src/zirh3_top.v
//
// The imported cluster attached to the loader through the exact ISP
// mux ZIRH-2 proved at gate level: the boot controller streams a
// CRC32-sealed image (from the UART pin through the loader's own
// receiver, or from QSPI-MRAM) into the SoC's ECC-protected bank while
// the SoC - its UART included - is held in reset; the STORED words are
// re-read and CRC'd; only a verified bank releases the CPU, whose
// fetch path muxes between the mask ROM and the bank. A refused image
// falls back to the immutable ROM.
//
// Differences from the ZIRH-2 die, all in ZIRH-3's favor:
//   * The loader runs PROTECT=1 - this die has the area for its
//     replicas (the ZIRH-2 placement campaign is the record of why the
//     TT die did not).
//   * The reset arrives conditioned from zirh_por_ro (POR/brown-out),
//     not from a harness.
//   * The JTAG debug module sits alongside, its halt/reset requests
//     gated by the flight lock (F27, Cycle 8).
//
// Not yet in this top (each a named later rung): the sram39 sliced
// bank as CPU data memory on a bus slot, the SBA-to-bus route, the
// housekeeping/telemetry cluster, the watchdog-revert signon wiring
// (signon/wd_fail are tied off until hk arrives to provide them).
// =============================================================================

`default_nettype none

module zirh3_top #(
    parameter ROM_HEX = "",
    parameter integer POR_CYCLES = 64,
    parameter integer RESET_DIV  = 174
) (
    input  wire        clk,
    input  wire        rst_n_pad,
    input  wire        pwr_good_i,

    // straps, sampled after POR
    input  wire        boot_strap_i,       // 1: host-ISP load, 0: golden ROM
    input  wire        dbg_unlock_strap_i,

    // the mission UART: ISP bytes during load, firmware I/O after
    input  wire        uart_rx_i,
    output wire        uart_tx_o,

    // JTAG debug port (behind the flight-locked gate)
    input  wire        tck_i,
    input  wire        tms_i,
    input  wire        tdi_i,
    output wire        tdo_o,
    input  wire        trst_n_i,

    // observability
    output wire        sys_rst_n_o,
    output wire        boot_sel_o,
    output wire        evt_boot_accept_o,
    output wire        evt_boot_reject_o,
    output wire        dbg_locked_o,
    output wire        err_o
);

    // --- conditioned reset + independent oscillator -------------------------
    wire sys_rst_n, ro_clk, ro_rst_n;
    zirh_por_ro #(.POR_CYCLES(POR_CYCLES)) u_porro (
        .clk(clk), .rst_n_pad(rst_n_pad), .pwr_good_i(pwr_good_i),
        .sys_rst_n_o(sys_rst_n), .ro_clk_o(ro_clk), .ro_rst_n_o(ro_rst_n));
    assign sys_rst_n_o = sys_rst_n;

    // --- the loader's own receiver (transport, not TMR) ---------------------
    wire [7:0] rx_data;
    wire       rx_valid;
    zirh_isp_rx #(.DIV(RESET_DIV)) u_isp_rx (
        .clk(clk), .rst_n(sys_rst_n), .rx_i(uart_rx_i),
        .data_o(rx_data), .valid_o(rx_valid));

    // --- the trusted loader, PROTECT=1 (the area exists here) ---------------
    wire        bl_cyc, bl_we, bl_sel, bl_err;
    wire [31:0] bl_adr, bl_dat, bl_rdt;
    wire        bl_ack, bl_acc, bl_rej;
    reg         isp_rejected_q;

    wire isp_hold  = boot_strap_i & ~bl_sel & ~isp_rejected_q;
    wire soc_rst_n = sys_rst_n & ~isp_hold;

    always @(posedge clk) begin
        if (!sys_rst_n)  isp_rejected_q <= 1'b0;
        else if (bl_rej) isp_rejected_q <= 1'b1;
    end

    zirh_boot_ctrl #(.BANK_WORDS(16), .PROTECT(1)) u_boot (
        .clk(clk), .rst_n(sys_rst_n),
        .strap_i({1'b0, boot_strap_i}),
        .st_valid_i(rx_valid), .st_data_i(rx_data), .st_ready_o(),
        .sig_ok_i(1'b1), .signon_i(1'b0), .wd_fail_i(1'b0),
        .m_cyc_o(bl_cyc), .m_adr_o(bl_adr), .m_dat_o(bl_dat), .m_we_o(bl_we),
        .m_rdt_i(bl_rdt), .m_ack_i(bl_ack),
        .boot_sel_o(bl_sel), .bank_o(),
        .evt_accept_o(bl_acc), .evt_reject_o(bl_rej), .err_o(bl_err));

    assign boot_sel_o        = bl_sel;
    assign evt_boot_accept_o = bl_acc;
    assign evt_boot_reject_o = bl_rej;

    // --- JTAG debug module, gated by the flight lock ------------------------
    wire dm_req_raw, dm_ndm_raw, jtag_err, gate_err;
    zirh_jtag_dm u_jtag (
        .tck(tck_i), .tms(tms_i), .tdi(tdi_i), .tdo(tdo_o), .trst_n(trst_n_i),
        .clk(clk), .rst_n(sys_rst_n), .core_halted_i(1'b0),
        .dm_debug_req_o(dm_req_raw), .dm_ndmreset_o(dm_ndm_raw),
        .dm_sba_cyc_o(), .dm_sba_adr_o(), .dm_sba_dat_o(), .dm_sba_we_o(),
        .sba_rdt_i(32'd0), .sba_ack_i(1'b0), .err_o(jtag_err));

    // gated debug: SERV has no halt port yet, so the gated outputs are
    // observability today and the core hookup is the debug-capable-core
    // step; the LOCK boundary is what this top proves
    zirh_dbg_gate u_gate (
        .clk(clk), .rst_n(sys_rst_n), .unlock_strap_i(dbg_unlock_strap_i),
        .dm_debug_req_i(dm_req_raw), .dm_ndmreset_i(dm_ndm_raw),
        .dm_sba_cyc_i(1'b0), .dm_sba_adr_i(32'd0), .dm_sba_dat_i(32'd0),
        .dm_sba_we_i(1'b0),
        .debug_req_o(), .ndmreset_o(), .sba_cyc_o(), .sba_adr_o(),
        .sba_dat_o(), .sba_we_o(),
        .locked_o(dbg_locked_o), .err_o(gate_err));

    // --- clock-loss observer on the die's own oscillator --------------------
    wire clkobs_err;
    zirh_clkobs u_clkobs (
        .clk(clk), .rst_n(sys_rst_n), .ro_clk(ro_clk), .ro_rst_n(ro_rst_n),
        .clear_i(1'b0), .clk_ok_o(), .evt_loss_o(), .loss_cnt_o(),
        .err_o(clkobs_err));

    // --- the imported cluster, attached through the proven mux --------------
    wire soc_err, s3_cyc, s4_cyc, s4_ack;
    wire [31:0] s_adr, s_dat, s4_rdt;
    wire [3:0]  s4_sel;
    wire        s_we;
    zirh_soc #(
        .ROM_HEX(ROM_HEX), .RESET_DIV(RESET_DIV)
    ) u_soc (
        .clk(clk),
        .rst_n(soc_rst_n),
        .por_rst_n_i(sys_rst_n),
        .isp_hold_i(isp_hold),
        .boot_sel_i(bl_sel),
        .isp_cyc_i(bl_cyc),
        .isp_adr_i(bl_adr),
        .isp_dat_i(bl_dat),
        .isp_we_i(bl_we),
        .isp_rdt_o(bl_rdt),
        .isp_ack_o(bl_ack),
        .uart_tx_o(uart_tx_o),
        .uart_rx_i(uart_rx_i),
        .tlm_data_i(8'h00),
        .tlm_valid_i(1'b0),
        .tlm_ready_o(),
        // slot 3 (housekeeping) acked immediately until hk arrives -
        // the torture harness's proven tie-off; a dead-slot zero-ack
        // would put every firmware hk write through the bus watchdog
        .s3_cyc_o(s3_cyc), .s3_adr_o(s_adr), .s3_dat_o(s_dat),
        .s3_we_o(s_we),
        .s3_rdt_i(32'h0), .s3_ack_i(s3_cyc),
        // slot 4: the sliced SECDED bank as CPU data memory (0x4000)
        .s4_cyc_o(s4_cyc), .s4_sel_o(s4_sel),
        .s4_rdt_i(s4_rdt), .s4_ack_i(s4_ack),
        .evt_bus_timeout_o(), .evt_ecc_corr_o(), .evt_ecc_uncorr_o(),
        .rx_ferr_o(),
        .err_o(soc_err));

    // --- the sliced SECDED bank on the data bus (rung 4) --------------------
    // five 1024x8 macros, one logical word, scrubbed in the background;
    // the CPU reads and writes it at 0x4000 like any slave, and every
    // access rides the corrected port
    wire bank_err;
    zirh_sram39 #(.SCRUB_DIV_LOG2(10)) u_bank (
        .clk(clk), .rst_n(sys_rst_n),
        .scrub_en_i(1'b1),
        .cyc_i(s4_cyc), .adr_i(s_adr), .dat_i(s_dat), .sel_i(s4_sel),
        .we_i(s_we), .rdt_o(s4_rdt), .ack_o(s4_ack),
        .evt_corr_o(), .evt_uncorr_o(), .evt_scrub_corr_o(),
        .err_o(bank_err),
        .bist_start_i(1'b0), .bist_mode_i(2'd0), .bist_busy_o(),
        .bist_pass_o(), .bist_fail_cnt_o(), .bist_fail_adr_o(),
        .bist_fail_map_o());

    assign err_o = bl_err | jtag_err | gate_err | clkobs_err | soc_err
                 | bank_err;

endmodule

`default_nettype wire
