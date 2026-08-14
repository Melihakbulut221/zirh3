// ZIRH-3 - memsys integration smoke: reset the subsystem, confirm it
// elaborates and comes out of reset with the loader in charge (golden
// strap -> boot_sel low, no spurious errors, debug locked at POR).
`default_nettype none
`timescale 1ns/1ps
module tb_memsys;
  reg clk = 0, rst_n = 0, ro_clk = 0, ro_rst_n = 0;
  always #20 clk = ~clk;
  always #70 ro_clk = ~ro_clk;   // independent, slower

  wire boot_sel, dbg_locked, err, clk_ok;

  zirh3_memsys dut (
    .clk(clk), .rst_n(rst_n), .ro_clk(ro_clk), .ro_rst_n(ro_rst_n),
    .boot_strap_i(2'b00), .dbg_unlock_strap_i(1'b0),
    .host_valid_i(1'b0), .host_data_i(8'h0), .host_ready_o(),
    .qspi_io_i(4'h0), .qspi_io_o(), .qspi_io_oe(), .qspi_sck_o(), .qspi_csn_o(),
    .scrub_en_i(1'b1),
    .dm_debug_req_i(1'b0), .dm_ndmreset_i(1'b0), .dbg_locked_o(dbg_locked),
    .boot_sel_o(boot_sel), .boot_bank_o(), .evt_boot_accept_o(),
    .evt_boot_reject_o(), .evt_ecc_corr_o(), .evt_ecc_uncorr_o(),
    .evt_scrub_corr_o(), .clk_ok_o(clk_ok), .evt_clk_loss_o(), .err_o(err));

  integer i;
  initial begin
    repeat (8) @(posedge clk);
    rst_n = 1; ro_rst_n = 1;
    // let it settle
    for (i = 0; i < 200; i = i + 1) @(posedge clk);
    if (boot_sel !== 1'b0) begin
      $display("FAIL: golden strap must not select a bank (boot_sel=%b)", boot_sel);
      $fatal(1);
    end
    if (dbg_locked !== 1'b1) begin
      $display("FAIL: debug must be locked at POR (locked=%b)", dbg_locked);
      $fatal(1);
    end
    if (err === 1'b1) begin
      $display("FAIL: spurious TMR error at rest (err=%b)", err);
      $fatal(1);
    end
    $display("MEMSYS_SMOKE: PASS (boot_sel=0, debug locked, no error at rest)");
    $finish;
  end
  initial begin #2_000_000; $display("FAIL: memsys smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
