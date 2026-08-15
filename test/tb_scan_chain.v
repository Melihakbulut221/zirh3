// ZIRH-3 - the stitched scan chain, proven by shifting (F28 rehearsal).
// The DUT is not RTL: it is the yosys-mapped, python-stitched GATE
// netlist of zirh_clkobs on real SG13G2 scan cells. Two proofs:
//   1) shift identity - a pattern pushed in at scan_si_i reappears at
//      scan_so_o exactly CHAIN bits later: every flop is in the chain,
//      in order, and nothing swallows a bit;
//   2) capture - one functional clock with reset held overwrites the
//      loaded all-ones with the synchronous reset state: the chain
//      really observes the flops, not a shadow register.
`default_nettype none
`timescale 1ns/1ps
module tb_scan_chain;
  parameter integer CHAIN = 1;   // -P override from the script

  reg clk = 0, rst_n = 0, ro_rst_n = 0;
  reg scan_en = 0, scan_si = 0;
  wire scan_so;

  always #20 clk = ~clk;

  // The observer's flops live in TWO clock domains (clk and the ring
  // oscillator); one chain threads them all, so scan mode must clock
  // them together. A real implementation muxes a test clock over every
  // domain clock under scan_en - the bench models exactly that by
  // driving both domains from the one tester clock.
  wire ro_clk = clk;

  zirh_clkobs dut (
    .clk(clk), .rst_n(rst_n), .ro_clk(ro_clk), .ro_rst_n(ro_rst_n),
    .clear_i(1'b0), .clk_ok_o(), .evt_loss_o(), .loss_cnt_o(), .err_o(),
    .scan_en_i(scan_en), .scan_si_i(scan_si), .scan_so_o(scan_so));

  integer i, errs = 0, ones = 0;
  reg [511:0] pat, got;

  task shift_bit(input b); begin
    scan_si = b;
    @(negedge clk);
    #1;
  end endtask

  initial begin
    // functional reset first: a defined starting state
    rst_n = 0; ro_rst_n = 0;
    repeat (5) @(negedge clk);

    // ---- proof 1: shift identity --------------------------------------
    scan_en = 1;
    pat = 512'h5A5A_D00D_C0DE_5A5A_1234_ABCD_5555_AAAA_F0F0_0FF0_5A3C;
    for (i = 0; i < CHAIN; i = i + 1)      // fill the chain
      shift_bit(pat[i % 173]);
    for (i = 0; i < CHAIN; i = i + 1) begin // push it through
      got[i] = scan_so;
      shift_bit(1'b1);                     // trailer: all-ones load
    end
    for (i = 0; i < CHAIN; i = i + 1)
      if (got[i] !== pat[i % 173]) errs = errs + 1;
    if (errs != 0) begin
      $display("FAIL: shift identity broke at %0d of %0d bits", errs, CHAIN);
      $fatal(1);
    end
    $display("  ok: %0d-bit chain shifted the pattern through intact", CHAIN);

    // ---- proof 2: capture overwrites the loaded ones ------------------
    // the chain now holds all-ones; one functional clock with reset
    // held captures the synchronous reset state instead
    scan_en = 0; rst_n = 0;
    @(negedge clk); #1;
    scan_en = 1;
    ones = 0;
    for (i = 0; i < CHAIN; i = i + 1) begin
      if (scan_so === 1'b1) ones = ones + 1;
      shift_bit(1'b0);
    end
    if (ones == CHAIN) begin
      $display("FAIL: capture cycle changed nothing - chain is a shadow");
      $fatal(1);
    end
    $display("  ok: capture cycle loaded the flops (%0d/%0d ones remain)",
             ones, CHAIN);

    $display("SCAN_CHAIN: PASS (%0d cells, shift + capture)", CHAIN);
    $finish;
  end
  initial begin #10_000_000; $display("FAIL: scan chain hung"); $fatal(1); end
endmodule
`default_nettype wire
