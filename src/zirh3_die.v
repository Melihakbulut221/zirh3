// =============================================================================
// ZIRH-3 - the standalone-die wrapper (POR/RO + memory subsystem)
// src/zirh3_die.v
//
// The first thing on this die that a TT harness would otherwise have
// provided: it takes only a raw pad reset and a brown-out signal - no
// external system reset, no external observer clock - and makes them
// itself. zirh_por_ro conditions the reset and generates the
// independent oscillator; zirh3_memsys attaches to both. This is the
// composition docs/SCOPE.md names as the dedicated die's genuinely-new
// silicon, wired to the proven subsystem beneath it.
//
// The SoC cluster is still the next import; when it lands it attaches
// to the same sys_rst_n and the same memory subsystem this wrapper
// already stands up.
// =============================================================================

`default_nettype none

module zirh3_die #(
    parameter integer POR_CYCLES     = 64,
    parameter integer BANK_WORDS     = 16,
    parameter integer SCRUB_DIV_LOG2 = 10
) (
    input  wire        clk,
    input  wire        rst_n_pad,     // raw pad reset
    input  wire        pwr_good_i,    // brown-out detector

    input  wire [1:0]  boot_strap_i,
    input  wire        dbg_unlock_strap_i,

    // host ISP arrives as a PIN: UART bytes at the reset baud through
    // the loader's own receiver (the ZIRH-2 pattern) - strap 11 selects
    // this transport, QSPI is the other
    input  wire        uart_rx_i,

    input  wire [3:0]  qspi_io_i,
    output wire [3:0]  qspi_io_o,
    output wire [3:0]  qspi_io_oe,
    output wire        qspi_sck_o,
    output wire        qspi_csn_o,

    // JTAG debug port (F27): pins into the on-die debug module, whose
    // requests reach the core only through the flight-locked gate
    input  wire        tck_i,
    input  wire        tms_i,
    input  wire        tdi_i,
    output wire        tdo_o,
    input  wire        trst_n_i,
    output wire        dbg_locked_o,

    output wire        sys_rst_n_o,     // observable: the conditioned reset
    output wire        clk_ok_o,
    output wire        evt_clk_loss_o,
    output wire        boot_sel_o,
    output wire        evt_boot_accept_o,
    output wire        evt_boot_reject_o,
    output wire        evt_ecc_corr_o,
    output wire        evt_ecc_uncorr_o,
    output wire        err_o
);

    wire sys_rst_n, ro_clk, ro_rst_n;
    wire dm_debug_req, dm_ndmreset, dm_jtag_err, memsys_err;

    // the JTAG debug module: its requests go to the gate inside memsys,
    // which is latched locked at POR (dbg_unlock_strap_i is the fuse).
    // The System Bus Access master is produced but not yet routed to the
    // bank - that memory-peek path is a follow-on rung; the halt/reset
    // path through the gate is the F27 core.
    zirh_jtag_dm u_jtag (
        .tck(tck_i), .tms(tms_i), .tdi(tdi_i), .tdo(tdo_o), .trst_n(trst_n_i),
        .clk(clk), .rst_n(sys_rst_n), .core_halted_i(1'b0),
        .dm_debug_req_o(dm_debug_req), .dm_ndmreset_o(dm_ndmreset),
        .dm_sba_cyc_o(), .dm_sba_adr_o(), .dm_sba_dat_o(), .dm_sba_we_o(),
        .sba_rdt_i(32'd0), .sba_ack_i(1'b0), .err_o(dm_jtag_err)
    );

    wire [7:0] isp_rx_data;
    wire       isp_rx_valid;

    zirh_por_ro #(.POR_CYCLES(POR_CYCLES)) u_porro (
        .clk        (clk),
        .rst_n_pad  (rst_n_pad),
        .pwr_good_i (pwr_good_i),
        .sys_rst_n_o(sys_rst_n),
        .ro_clk_o   (ro_clk),
        .ro_rst_n_o (ro_rst_n)
    );
    assign sys_rst_n_o = sys_rst_n;

    zirh_isp_rx #(.DIV(174)) u_isp_rx (
        .clk    (clk),
        .rst_n  (sys_rst_n),
        .rx_i   (uart_rx_i),
        .data_o (isp_rx_data),
        .valid_o(isp_rx_valid)
    );

    zirh3_memsys #(
        .BANK_WORDS(BANK_WORDS), .SCRUB_DIV_LOG2(SCRUB_DIV_LOG2)
    ) u_memsys (
        .clk               (clk),
        .rst_n             (sys_rst_n),
        .ro_clk            (ro_clk),
        .ro_rst_n          (ro_rst_n),
        .boot_strap_i      (boot_strap_i),
        .dbg_unlock_strap_i(dbg_unlock_strap_i),
        .host_valid_i      (isp_rx_valid),
        .host_data_i       (isp_rx_data),
        .host_ready_o      (),
        .qspi_io_i         (qspi_io_i),
        .qspi_io_o         (qspi_io_o),
        .qspi_io_oe        (qspi_io_oe),
        .qspi_sck_o        (qspi_sck_o),
        .qspi_csn_o        (qspi_csn_o),
        .scrub_en_i        (1'b1),
        .dm_debug_req_i    (dm_debug_req),
        .dm_ndmreset_i     (dm_ndmreset),
        .dbg_locked_o      (dbg_locked_o),
        .boot_sel_o        (boot_sel_o),
        .boot_bank_o       (),
        .evt_boot_accept_o (evt_boot_accept_o),
        .evt_boot_reject_o (evt_boot_reject_o),
        .evt_ecc_corr_o    (evt_ecc_corr_o),
        .evt_ecc_uncorr_o  (evt_ecc_uncorr_o),
        .evt_scrub_corr_o  (),
        .clk_ok_o          (clk_ok_o),
        .evt_clk_loss_o    (evt_clk_loss_o),
        .err_o             (memsys_err)
    );

    assign err_o = memsys_err | dm_jtag_err;

endmodule

`default_nettype wire
