// =============================================================================
// ZIRH-3 - the memory + boot subsystem integration skeleton
// src/zirh3_memsys.v
//
// The first integration artifact of the dedicated die: the verified
// blocks wired into one coherent subsystem, harness-independent, so
// the SoC cluster drops onto a proven substrate later. What it wires:
//
//   - zirh_boot_ctrl (the trusted loader) as the MASTER during boot,
//     streaming a verified image into...
//   - zirh_sram39 (the 5-slice SECDED bank memory) - a stronger
//     demonstration than ZIRH-2, where the loader filled a 64 B ECC
//     RAM; here it fills the real macro-backed sliced memory the
//     product carries
//   - zirh_qspi as the image source (external MRAM transport)
//   - zirh_clkobs watching an independent RO clock for main-clock SEFI
//   - zirh_dbg_gate isolating the debug port behind the flight lock
//
// The bus is deliberately simple: one master at a time. During boot
// the loader owns the sram39 port; after commit, boot_sel_o hands the
// port to the (future) CPU fetch/data path, exactly the mux ZIRH-2
// proved. The CPU/SoC cluster is NOT in this repository yet - importing
// it is the next step in docs/PROGRAM.md; this skeleton is the memory
// substrate it will attach to, and it stands on its own: it
// elaborates, lints clean, and every block inside keeps its TMR
// through synthesis (scripts/check_tmr.sh).
// =============================================================================

`default_nettype none

module zirh3_memsys #(
    parameter integer BANK_WORDS     = 16,   // sram39 addressable words
    parameter integer SCRUB_DIV_LOG2 = 10
) (
    input  wire        clk,
    input  wire        rst_n,

    // independent oscillator for the clock-loss observer
    input  wire        ro_clk,
    input  wire        ro_rst_n,

    // image source select + straps
    input  wire [1:0]  boot_strap_i,   // 00 golden 01 A 10 B 11 host
    input  wire        dbg_unlock_strap_i,

    // host image stream (when strap = host); QSPI drives the bank-image
    // path when booting from MRAM
    input  wire        host_valid_i,
    input  wire [7:0]  host_data_i,
    output wire        host_ready_o,

    // QSPI pins (to external MRAM): quad io bus + chip select
    input  wire [3:0]  qspi_io_i,
    output wire [3:0]  qspi_io_o,
    output wire [3:0]  qspi_io_oe,
    output wire        qspi_sck_o,
    output wire        qspi_csn_o,

    // scrubber enable for the bank
    input  wire        scrub_en_i,

    // debug port (from a future riscv-dbg module, behind the gate)
    input  wire        dm_debug_req_i,
    input  wire        dm_ndmreset_i,
    output wire        dbg_locked_o,

    // subsystem observability
    output wire        boot_sel_o,      // 0 golden/ROM, 1 run from bank
    output wire        boot_bank_o,
    output wire        evt_boot_accept_o,
    output wire        evt_boot_reject_o,
    output wire        evt_ecc_corr_o,
    output wire        evt_ecc_uncorr_o,
    output wire        evt_scrub_corr_o,
    output wire        clk_ok_o,
    output wire        evt_clk_loss_o,
    output wire        err_o            // any block's TMR mismatch
);

    // --- the loader as boot master -----------------------------------------
    wire        bl_cyc, bl_we;
    wire [31:0] bl_adr, bl_dat, bl_rdt;
    wire        bl_ack, bl_err;

    // host vs QSPI image stream into the loader: the loader is
    // transport-agnostic (ZIRH-2 lesson), so a simple select feeds it
    // either the host bytes or the QSPI read stream
    wire        q_valid, q_ready;
    wire [7:0]  q_data;
    wire        use_host = (boot_strap_i == 2'b11);

    wire        st_valid = use_host ? host_valid_i : q_valid;
    wire [7:0]  st_data  = use_host ? host_data_i  : q_data;
    assign host_ready_o  = use_host & q_ready;

    zirh_boot_ctrl #(.BANK_WORDS(BANK_WORDS), .PROTECT(1)) u_boot (
        .clk          (clk),
        .rst_n        (rst_n),
        .strap_i      (boot_strap_i),
        .st_valid_i   (st_valid),
        .st_data_i    (st_data),
        .st_ready_o   (q_ready),
        .sig_ok_i     (1'b1),
        .signon_i     (1'b0),
        .wd_fail_i    (1'b0),
        .m_cyc_o      (bl_cyc),
        .m_adr_o      (bl_adr),
        .m_dat_o      (bl_dat),
        .m_we_o       (bl_we),
        .m_rdt_i      (bl_rdt),
        .m_ack_i      (bl_ack),
        .boot_sel_o   (boot_sel_o),
        .bank_o       (boot_bank_o),
        .evt_accept_o (evt_boot_accept_o),
        .evt_reject_o (evt_boot_reject_o),
        .err_o        (bl_err)
    );

    // --- the sliced SECDED bank the loader fills ----------------------------
    wire sram_err;
    zirh_sram39 #(.SCRUB_DIV_LOG2(SCRUB_DIV_LOG2)) u_bank (
        .clk              (clk),
        .rst_n            (rst_n),
        .scrub_en_i       (scrub_en_i & boot_sel_o),  // scrub only a live bank
        .cyc_i            (bl_cyc),
        .adr_i            (bl_adr),
        .dat_i            (bl_dat),
        .sel_i            (4'hF),
        .we_i             (bl_we),
        .rdt_o            (bl_rdt),
        .ack_o            (bl_ack),
        .evt_corr_o       (evt_ecc_corr_o),
        .evt_uncorr_o     (evt_ecc_uncorr_o),
        .evt_scrub_corr_o (evt_scrub_corr_o),
        .err_o            (sram_err),
        .bist_start_i     (1'b0),
        .bist_mode_i      (2'd0),
        .bist_busy_o      (),
        .bist_pass_o      (),
        .bist_fail_cnt_o  (),
        .bist_fail_adr_o  (),
        .bist_fail_map_o  ()
    );

    // --- QSPI-MRAM image source --------------------------------------------
    wire qspi_err;
    zirh_qspi u_qspi (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_i    (~use_host & (boot_strap_i != 2'b00)),
        .quad_i     (1'b0),
        .addr_i     (24'd0),
        .len_i      (24'(BANK_WORDS * 4 + 12)),
        .abort_i    (1'b0),
        .busy_o     (),
        .st_valid_o (q_valid),
        .st_data_o  (q_data),
        .st_ready_i (q_ready & ~use_host),
        .sck_o      (qspi_sck_o),
        .cs_n_o     (qspi_csn_o),
        .io_o       (qspi_io_o),
        .io_oe      (qspi_io_oe),
        .io_i       (qspi_io_i),
        .err_o      (qspi_err)
    );

    // --- clock-loss observer -----------------------------------------------
    wire clkobs_err;
    zirh_clkobs u_clkobs (
        .clk       (clk),
        .rst_n     (rst_n),
        .ro_clk    (ro_clk),
        .ro_rst_n  (ro_rst_n),
        .clear_i   (1'b0),
        .clk_ok_o  (clk_ok_o),
        .evt_loss_o(evt_clk_loss_o),
        .loss_cnt_o(),
        .err_o     (clkobs_err)
    );

    // --- debug isolation gate ----------------------------------------------
    wire dbg_err;
    zirh_dbg_gate u_dbg (
        .clk            (clk),
        .rst_n          (rst_n),
        .unlock_strap_i (dbg_unlock_strap_i),
        .dm_debug_req_i (dm_debug_req_i),
        .dm_ndmreset_i  (dm_ndmreset_i),
        .dm_sba_cyc_i   (1'b0),
        .dm_sba_adr_i   (32'd0),
        .dm_sba_dat_i   (32'd0),
        .dm_sba_we_i    (1'b0),
        .debug_req_o    (),
        .ndmreset_o     (),
        .sba_cyc_o      (),
        .sba_adr_o      (),
        .sba_dat_o      (),
        .sba_we_o       (),
        .locked_o       (dbg_locked_o),
        .err_o          (dbg_err)
    );

    assign err_o = bl_err | sram_err | qspi_err | clkobs_err | dbg_err;

endmodule

`default_nettype wire
