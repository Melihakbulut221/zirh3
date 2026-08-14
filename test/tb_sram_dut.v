// ZIRH-3 - SRAM DUT experiment smoke: a clean scan of the bare macros
// finds ZERO failures (the pre-beam baseline). Under beam, mismatches
// stream out as (fail_adr, fail_map); on the bench with no radiation
// the array is perfect, which is exactly the baseline a campaign
// subtracts.
`default_nettype none
`timescale 1ns/1ps
module tb_sram_dut;
  reg clk = 0, rst_n = 0, start = 0;
  reg [1:0] mode = 0;
  always #20 clk = ~clk;
  wire busy, pass, err;
  wire [15:0] fail_cnt;
  wire [9:0] fail_adr;
  wire [4:0] fail_map;

  zirh_sram_dut dut (
    .clk(clk), .rst_n(rst_n), .start_i(start), .mode_i(mode),
    .busy_o(busy), .pass_o(pass), .fail_cnt_o(fail_cnt),
    .fail_adr_o(fail_adr), .fail_map_o(fail_map), .err_o(err));

  integer i;
  initial begin
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    // launch a march c- scan
    mode = 2'd0; start = 1; @(posedge clk); start = 0;
    // wait for the scan to finish
    for (i = 0; i < 200000 && (busy || i < 10); i = i + 1) @(posedge clk);
    if (busy) begin $display("FAIL: scan never finished"); $fatal(1); end
    if (err === 1'b1) begin $display("FAIL: engine TMR error"); $fatal(1); end
    if (fail_cnt !== 16'd0) begin
      $display("FAIL: clean macros reported %0d failures (adr=%0h map=%b)",
               fail_cnt, fail_adr, fail_map); $fatal(1);
    end
    if (pass !== 1'b1) begin $display("FAIL: pass not asserted on a clean scan"); $fatal(1); end
    $display("SRAM_DUT_SMOKE: PASS (clean array, zero failures - the beam baseline)");
    $finish;
  end
  initial begin #20_000_000; $display("FAIL: sram_dut smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
