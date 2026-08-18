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
    parameter integer RESET_DIV  = 174,
    parameter integer INTERVAL_LOG2 = 16,
    parameter integer WD_LIMIT_LOG2 = 20,
    parameter integer BANK_PAGES    = 16,
    parameter integer BANK_WORDS    = 32768,
    parameter integer BANK_DEPTH    = 4096
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
    // sys_rst_n_o is driven at the bottom of the file, through the
    // boundary-scan pin mux (F28)

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

    wire wd_rst;    // from hk's CPU watchdog (resets the SoC only)
    wire isp_hold  = boot_strap_i & ~bl_sel & ~isp_rejected_q;
    wire soc_rst_n = sys_rst_n & ~isp_hold & ~wd_rst;

    // --- the watchdog-revert signon (the last rung's load-bearing piece) ----
    // A loaded bank signs on the moment its firmware writes the telemetry
    // signature - hk pulses cpu_alive per CPU_SIG write, so sign-on costs
    // zero new detection. The watchdog verdict toward the loader is
    // grace-gated by one full watchdog period, so a starvation pulse left
    // over from the ISP hold cannot fail a bank that never had a chance to
    // run. This is the ZIRH-2 revert logic, unchanged.
    wire cpu_alive;
    reg  signon_seen_q;
    reg  [WD_LIMIT_LOG2:0] run_age_q;
    wire signon     = bl_sel & cpu_alive;
    wire wd_verdict = wd_rst & bl_sel & (signon_seen_q | run_age_q[WD_LIMIT_LOG2]);
    always @(posedge clk) begin
        if (!sys_rst_n) begin
            signon_seen_q <= 1'b0;
            run_age_q     <= {(WD_LIMIT_LOG2+1){1'b0}};
        end else begin
            if (signon) signon_seen_q <= 1'b1;
            if (bl_sel & ~run_age_q[WD_LIMIT_LOG2]) run_age_q <= run_age_q + 1'b1;
        end
    end

    // isp_hold owns the SoC only while the loader is still deciding. Once
    // it commits (bl_sel) the CPU runs; if a committed bank is later
    // FAILED by the watchdog and reverted, that bank counts as rejected
    // for hold purposes too - otherwise isp_hold would reassert
    // (boot_strap high, bl_sel back to 0) and pin the golden CPU in reset
    // forever. A watchdog revert is a reject we will not re-hold for.
    always @(posedge clk) begin
        if (!sys_rst_n)             isp_rejected_q <= 1'b0;
        else if (bl_rej | wd_verdict) isp_rejected_q <= 1'b1;
    end

    zirh_boot_ctrl #(.BANK_WORDS(BANK_WORDS), .PROTECT(1)) u_boot (
        .clk(clk), .rst_n(sys_rst_n),
        .strap_i({1'b0, boot_strap_i}),
        .st_valid_i(rx_valid), .st_data_i(rx_data), .st_ready_o(),
        .sig_ok_i(1'b1), .signon_i(signon), .wd_fail_i(wd_verdict),
        .m_cyc_o(bl_cyc), .m_adr_o(bl_adr), .m_dat_o(bl_dat), .m_we_o(bl_we),
        .m_rdt_i(bl_rdt), .m_ack_i(bl_ack),
        .boot_sel_o(bl_sel), .bank_o(),
        .evt_accept_o(bl_acc), .evt_reject_o(bl_rej), .err_o(bl_err));

    // boot_sel_o / evt_boot_*_o are driven at the bottom of the file,
    // through the boundary-scan pin mux (F28)

    // --- JTAG debug module, gated by the flight lock ------------------------
    wire dm_req_raw, dm_ndm_raw, jtag_err, gate_err;
    wire dbg_locked, uart_tx_int, bs_extest;
    wire [11:0] bs_cap;
    wire [6:0]  bs_drv;
    wire        dm_sba_cyc, dm_sba_we;
    wire [31:0] dm_sba_adr, dm_sba_dat;
    wire        sba_cyc, sba_we;           // gated, into the arbiter
    wire [31:0] sba_adr, sba_dat;
    wire [31:0] sba_rdt;                   // read return from the bank
    wire        sba_ack;

    // The POR resets the TAP too (TRST wired to trst_n AND the
    // conditioned reset): a die that never sees a debugger would
    // otherwise power up with tap/ir undefined, and that undefinedness
    // leaks through dmi_update_lvl into the DM's TMR replicas - worse,
    // on real silicon a random power-up TAP state could fire a spurious
    // DMI write before any tool attaches. Found by the boundary-scan
    // bench the moment it started CHECKING the err pin.
    zirh_jtag_dm u_jtag (
        .tck(tck_i), .tms(tms_i), .tdi(tdi_i), .tdo(tdo_o),
        .trst_n(trst_n_i & sys_rst_n),
        .clk(clk), .rst_n(sys_rst_n), .core_halted_i(1'b0),
        .dm_debug_req_o(dm_req_raw), .dm_ndmreset_o(dm_ndm_raw),
        .dm_sba_cyc_o(dm_sba_cyc), .dm_sba_adr_o(dm_sba_adr),
        .dm_sba_dat_o(dm_sba_dat), .dm_sba_we_o(dm_sba_we),
        .sba_rdt_i(sba_rdt), .sba_ack_i(sba_ack),
        .bs_cap_i(bs_cap), .bs_drv_o(bs_drv), .bs_extest_o(bs_extest),
        .err_o(jtag_err));

    // the gate masks the DM's every request; the SBA path now reaches
    // real memory (the sliced bank), so a debugger can peek/poke without
    // halting the core - inert in flight, live on the bench, exactly
    // like the halt request. SERV has no halt port yet, so debug_req is
    // still observability; the SBA memory path is what rung 5 adds.
    zirh_dbg_gate u_gate (
        .clk(clk), .rst_n(sys_rst_n), .unlock_strap_i(dbg_unlock_strap_i),
        .dm_debug_req_i(dm_req_raw), .dm_ndmreset_i(dm_ndm_raw),
        .dm_sba_cyc_i(dm_sba_cyc), .dm_sba_adr_i(dm_sba_adr),
        .dm_sba_dat_i(dm_sba_dat), .dm_sba_we_i(dm_sba_we),
        .debug_req_o(), .ndmreset_o(),
        .sba_cyc_o(sba_cyc), .sba_adr_o(sba_adr),
        .sba_dat_o(sba_dat), .sba_we_o(sba_we),
        .locked_o(dbg_locked), .err_o(gate_err));

    // --- clock-loss observer on the die's own oscillator --------------------
    wire clkobs_err;
    zirh_clkobs u_clkobs (
        .clk(clk), .rst_n(sys_rst_n), .ro_clk(ro_clk), .ro_rst_n(ro_rst_n),
        .clear_i(1'b0), .clk_ok_o(), .evt_loss_o(), .loss_cnt_o(),
        .err_o(clkobs_err));

    // --- the imported cluster, attached through the proven mux --------------
    wire soc_err, s3_cyc, s4_cyc, s4_ack, s5_cyc;
    wire        bf_cyc, bf_ack;
    wire [31:0] bf_adr, bf_rdt;
    wire        mb_start, mb_busy, mb_pass, mb_ack, mb_err;
    wire [1:0]  mb_mode;
    wire [15:0] mb_fcnt;
    wire [11:0] mb_fadr;
    wire [4:0]  mb_fmap;
    wire [31:0] mb_rdt;
    wire [5:0]  mb_page;
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
        // Cycle 17: the loader writes the TOP's program store now;
        // the soc's ISP-into-RAM path stays tied for contract
        // stability (isp_hold still holds the cluster in reset)
        .isp_cyc_i(1'b0),
        .isp_adr_i(32'd0),
        .isp_dat_i(32'd0),
        .isp_we_i(1'b0),
        .isp_rdt_o(),
        .isp_ack_o(),
        .uart_tx_o(uart_tx_int),
        .uart_rx_i(uart_rx_i),
        .tlm_data_i(tlm_data),
        .tlm_valid_i(tlm_valid),
        .tlm_ready_o(tlm_ready),
        // slot 3: the housekeeping block (counters, watchdog, signature)
        .s3_cyc_o(s3_cyc), .s3_adr_o(s_adr), .s3_dat_o(s_dat),
        .s3_we_o(s_we),
        .s3_rdt_i(hk_rdt), .s3_ack_i(hk_ack),
        // slot 4: the sliced SECDED bank as CPU data memory (0x4000)
        .s4_cyc_o(s4_cyc), .s4_sel_o(s4_sel),
        .s4_rdt_i(s4_rdt), .s4_ack_i(s4_ack),
        // slot 5: the MBIST doorway (0x5000)
        .s5_cyc_o(s5_cyc),
        .s5_rdt_i(mb_rdt), .s5_ack_i(mb_ack),
        // boot fetch: loaded code runs from the program store
        .bf_cyc_o(bf_cyc), .bf_adr_o(bf_adr),
        .bf_rdt_i(bf_rdt), .bf_ack_i(bf_ack),
        .evt_bus_timeout_o(), .evt_ecc_corr_o(), .evt_ecc_uncorr_o(),
        .rx_ferr_o(),
        .err_o(soc_err));

    // --- the sliced SECDED bank on the data bus (rungs 4-5) -----------------
    // five 1024x8 macros, one logical word, scrubbed in the background.
    // Two masters share its single port: the CPU at slot 4 (0x4000), and
    // the debugger's gated System Bus Access (rung 5). SBA takes priority
    // when it holds cyc - which it can only do UNLOCKED (the gate forces
    // it inert in flight), so a flight CPU never contends with a debug
    // peek. The bank's own ~ack framing keeps each transaction clean.
    wire bank_err;

    // Cycle 17, the program-store arbiter: four masters share the
    // bank's one port. Priority SBA > loader > CPU data > fetch -
    // the debugger only exists unlocked, the loader only exists while
    // the CPU is held, data beats fetch because the I-cache absorbs
    // fetch stalls for free. Every full-address master reads the bank
    // FLAT; only the CPU's slot-4 data window rides the page register.
    wire g_sba = sba_cyc;
    wire g_bl  = bl_cyc & ~sba_cyc;
    wire g_s4  = s4_cyc & ~sba_cyc & ~bl_cyc;
    wire g_bf  = bf_cyc & ~sba_cyc & ~bl_cyc & ~s4_cyc;

    wire        bank_cyc  = sba_cyc | bl_cyc | s4_cyc | bf_cyc;
    wire [31:0] bank_adr  = g_sba ? sba_adr :
                            g_bl  ? bl_adr  :
                            g_s4  ? s_adr   : bf_adr;
    wire [31:0] bank_dat  = g_sba ? sba_dat :
                            g_bl  ? bl_dat  : s_dat;
    wire [3:0]  bank_sel  = g_s4  ? s4_sel  : 4'hF;
    wire        bank_we   = g_sba ? sba_we  :
                            g_bl  ? bl_we   :
                            g_s4  ? s_we    : 1'b0;
    wire        bank_flat = g_sba | g_bl | g_bf;
    wire [31:0] bank_rdt;
    wire        bank_ack;

    // Cycle 14 rung 5: 64 KB of the proven sliced-SECDED bank. The
    // CPU pages its 4 KB window through the doorway's PAGE register;
    // the debugger's SBA carries a full address and reads the flat
    // 64 KB (sba_cyc marks whose access this is).
    zirh_bank64 #(.SCRUB_DIV_LOG2(10), .PAGES(BANK_PAGES), .DEPTH(BANK_DEPTH)) u_bank (
        .clk(clk), .rst_n(sys_rst_n),
        .scrub_en_i(1'b1),
        .page_i(mb_page), .sba_flat_i(bank_flat),
        .cyc_i(bank_cyc), .adr_i(bank_adr), .dat_i(bank_dat),
        .sel_i(bank_sel), .we_i(bank_we), .rdt_o(bank_rdt), .ack_o(bank_ack),
        .evt_corr_o(), .evt_uncorr_o(), .evt_scrub_corr_o(),
        .err_o(bank_err),
        .bist_start_i(mb_start), .bist_mode_i(mb_mode),
        .bist_busy_o(mb_busy), .bist_pass_o(mb_pass),
        .bist_fail_cnt_o(mb_fcnt), .bist_fail_adr_o(mb_fadr),
        .bist_fail_map_o(mb_fmap));

    // --- the MBIST doorway: software runs the bank's march test -------------
    // The engine has lived inside sram39 since its bring-up; this doorway
    // at slot 5 is what F28 adds - a manufacturing-test program arrives
    // over the ISP like any other image, and an in-flight self-test is
    // one firmware loop away.
    zirh_mbist u_mbist (
        .clk(clk), .rst_n(sys_rst_n),
        .cyc_i(s5_cyc), .adr_i(s_adr), .dat_i(s_dat), .we_i(s_we),
        .rdt_o(mb_rdt), .ack_o(mb_ack),
        .bist_start_o(mb_start), .bist_mode_o(mb_mode),
        .bist_busy_i(mb_busy), .bist_pass_i(mb_pass),
        .bist_fail_cnt_i(mb_fcnt), .bist_fail_adr_i(mb_fadr),
        .bist_fail_map_i(mb_fmap),
        .page_o(mb_page),
        .err_o(mb_err));

    // route the shared ack/data back to whichever master owns the cycle
    assign sba_rdt = bank_rdt;
    assign sba_ack = bank_ack & g_sba;
    assign bl_rdt  = bank_rdt;
    assign bl_ack  = bank_ack & g_bl;
    assign s4_rdt  = bank_rdt;
    assign s4_ack  = bank_ack & g_s4;
    assign bf_rdt  = bank_rdt;
    assign bf_ack  = bank_ack & g_bf;

    // --- housekeeping: counters, the CPU watchdog, the signature ------------
    wire [31:0] hk_rdt;
    wire        hk_ack, hk_infra;
    wire [15:0] c_plain, c_raw_a, c_esc_a, c_raw_b, c_esc_b;
    wire [7:0]  c_ecc_c, c_ecc_u, c_busto, c_ferr, boot_cnt, cpu_sig;
    wire [1:0]  hk_mode;
    wire        hk_armed;

    zirh_hk #(.WD_LIMIT_LOG2(WD_LIMIT_LOG2)) u_hk (
        .clk(clk), .rst_n(sys_rst_n),
        .cyc_i(s3_cyc), .adr_i(s_adr), .dat_i(s_dat), .we_i(s_we),
        .rdt_o(hk_rdt), .ack_o(hk_ack),
        .ecc_corr_i(1'b0), .ecc_uncorr_i(1'b0),
        .bus_to_i(1'b0), .rx_ferr_i(1'b0),
        .cnt_plain_o(c_plain), .cnt_raw_a_o(c_raw_a), .cnt_esc_a_o(c_esc_a),
        .cnt_raw_b_o(c_raw_b), .cnt_esc_b_o(c_esc_b),
        .cnt_ecc_c_o(c_ecc_c), .cnt_ecc_u_o(c_ecc_u),
        .cnt_bus_to_o(c_busto), .cnt_ferr_o(c_ferr),
        .boot_cnt_o(boot_cnt), .cpu_sig_o(cpu_sig),
        .mode_o(hk_mode), .armed_o(hk_armed),
        .err_infra_o(hk_infra), .evt_o(),
        .cpu_alive_o(cpu_alive), .wd_rst_o(wd_rst),
        .env_ro_i(32'd0), .env_sb_i(32'd0),
        .env_start_o(), .env_test_o(), .clear_o());

    // --- telemetry framer: unprompted frames on the shared UART -------------
    wire [7:0] tlm_data;
    wire       tlm_valid, tlm_ready, tlm_err;
    zirh_tlm2 #(.INTERVAL_LOG2(INTERVAL_LOG2)) u_tlm (
        .clk(clk), .rst_n(sys_rst_n),
        .cnt_plain_i(c_plain), .cnt_raw_a_i(c_raw_a), .cnt_esc_a_i(c_esc_a),
        .cnt_raw_b_i(c_raw_b), .cnt_esc_b_i(c_esc_b),
        .cnt_ecc_c_i(c_ecc_c), .cnt_ecc_u_i(c_ecc_u),
        .cpu_sig_i(cpu_sig), .boot_cnt_i(boot_cnt),
        .cnt_bus_to_i(c_busto), .cnt_ferr_i(c_ferr),
        .armed_i(hk_armed), .mode_i(hk_mode), .err_infra_i(hk_infra),
        .tx_data_o(tlm_data), .tx_valid_o(tlm_valid), .tx_ready_i(tlm_ready),
        .err_o(tlm_err));

    wire err_int = bl_err | jtag_err | gate_err | clkobs_err | soc_err
                 | bank_err | hk_infra | tlm_err | mb_err;

    // --- boundary scan at the pins (F28) ------------------------------------
    // SAMPLE captures the functional pin values through bs_cap; EXTEST
    // drives the output pins from the TAP's update latch - but only when
    // the flight fuse says bench. A locked die's pins are untouchable
    // from the TAP: the same absorbing lock that guards halt and SBA
    // guards the boundary cells.
    wire extest_drive = bs_extest & ~dbg_locked;

    assign bs_cap = {err_int, dbg_locked, bl_rej, bl_acc, bl_sel,
                     sys_rst_n, uart_tx_int,
                     uart_rx_i, dbg_unlock_strap_i, boot_strap_i,
                     pwr_good_i, rst_n_pad};

    assign uart_tx_o         = extest_drive ? bs_drv[0] : uart_tx_int;
    assign sys_rst_n_o       = extest_drive ? bs_drv[1] : sys_rst_n;
    assign boot_sel_o        = extest_drive ? bs_drv[2] : bl_sel;
    assign evt_boot_accept_o = extest_drive ? bs_drv[3] : bl_acc;
    assign evt_boot_reject_o = extest_drive ? bs_drv[4] : bl_rej;
    assign dbg_locked_o      = extest_drive ? bs_drv[5] : dbg_locked;
    assign err_o             = extest_drive ? bs_drv[6] : err_int;

endmodule

`default_nettype wire
