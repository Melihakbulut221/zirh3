// ZIRH-3 - die-level smoke: raw pad reset + power-good in, the die
// conditions its own reset, runs its own observer clock, and brings up
// the memory subsystem (loader in charge, debug locked, no error).
`default_nettype none
`timescale 1ns/1ps
module tb_die;
  reg clk = 0, rst_n_pad = 0, pwr_good = 1;
  always #20 clk = ~clk;
  wire sys_rst_n, boot_sel, dbg_locked, err, clk_ok;

  zirh3_die #(.POR_CYCLES(64)) dut (
    .clk(clk), .rst_n_pad(rst_n_pad), .pwr_good_i(pwr_good),
    .boot_strap_i(2'b00), .dbg_unlock_strap_i(1'b0),
    .uart_rx_i(1'b1),
    .qspi_io_i(4'h0), .qspi_io_o(), .qspi_io_oe(), .qspi_sck_o(), .qspi_csn_o(),
    .tck_i(1'b0), .tms_i(1'b0), .tdi_i(1'b0), .tdo_o(), .trst_n_i(1'b1),
    .dbg_locked_o(dbg_locked),
    .sys_rst_n_o(sys_rst_n), .clk_ok_o(clk_ok), .evt_clk_loss_o(),
    .boot_sel_o(boot_sel), .evt_boot_accept_o(), .evt_boot_reject_o(),
    .evt_ecc_corr_o(), .evt_ecc_uncorr_o(), .err_o(err));

  integer i;
  initial begin
    repeat (5) @(posedge clk);
    if (sys_rst_n !== 1'b0) begin $display("FAIL: die reset not asserted under pad"); $fatal(1); end
    rst_n_pad = 1;
    // the die must condition its own reset through the POR window, then
    // bring the subsystem up
    for (i = 0; i < 300; i = i + 1) @(posedge clk);
    if (sys_rst_n !== 1'b1) begin $display("FAIL: die never released reset"); $fatal(1); end
    if (boot_sel !== 1'b0) begin $display("FAIL: golden strap selected a bank"); $fatal(1); end
    if (dbg_locked !== 1'b1) begin $display("FAIL: debug not locked at POR"); $fatal(1); end
    if (err === 1'b1) begin $display("FAIL: spurious TMR error"); $fatal(1); end
    $display("DIE_SMOKE: PASS (self-conditioned reset, loader in charge, debug locked, no error)");
    $finish;
  end
  initial begin #3_000_000; $display("FAIL: die smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
