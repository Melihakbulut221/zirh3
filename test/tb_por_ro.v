// ZIRH-3 - POR/RO sequence smoke: reset holds through the settle window,
// releases clean, the RO clock runs independently, and a brown-out
// re-arms the whole sequence.
`default_nettype none
`timescale 1ns/1ps
module tb_por_ro;
  reg clk = 0, rst_n_pad = 0, pwr_good = 1;
  always #20 clk = ~clk;
  wire sys_rst_n, ro_clk, ro_rst_n;

  zirh_por_ro #(.POR_CYCLES(64), .RO_DIV_LOG2(2)) dut (
    .clk(clk), .rst_n_pad(rst_n_pad), .pwr_good_i(pwr_good),
    .sys_rst_n_o(sys_rst_n), .ro_clk_o(ro_clk), .ro_rst_n_o(ro_rst_n));

  integer ro_edges = 0; reg ro_p = 0;
  always @(posedge clk) begin ro_p <= ro_clk; if (ro_clk & ~ro_p) ro_edges = ro_edges + 1; end

  integer i;
  initial begin
    // pad asserted: reset must be low
    repeat (5) @(posedge clk);
    if (sys_rst_n !== 1'b0) begin $display("FAIL: reset not asserted under pad"); $fatal(1); end
    rst_n_pad = 1;
    // must stay low through the settle window (< 64 cycles)
    repeat (30) @(posedge clk);
    if (sys_rst_n !== 1'b0) begin $display("FAIL: reset released before settle"); $fatal(1); end
    // must be released after the window
    repeat (60) @(posedge clk);
    if (sys_rst_n !== 1'b1) begin $display("FAIL: reset never released"); $fatal(1); end
    if (ro_edges < 3) begin $display("FAIL: RO clock not running (%0d edges)", ro_edges); $fatal(1); end
    // brown-out: drop power, reset must re-arm
    pwr_good = 0;
    repeat (5) @(posedge clk);
    if (sys_rst_n !== 1'b0) begin $display("FAIL: brown-out did not re-arm reset"); $fatal(1); end
    pwr_good = 1;
    repeat (70) @(posedge clk);
    if (sys_rst_n !== 1'b1) begin $display("FAIL: reset never re-released after brown-out"); $fatal(1); end
    $display("POR_RO_SMOKE: PASS (settle hold, clean release, RO runs, brown-out re-arm)");
    $finish;
  end
  initial begin #500000; $display("FAIL: por_ro smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
