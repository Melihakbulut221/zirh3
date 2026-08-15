// ZIRH-3 - the stitched-TMR netlist under fire (Cycle 14 rung 3, pilot B).
// The DUT is the gate-level LFSR after tmr_stitch.py: every flop
// tripled, a voter owning each original Q net. Proofs:
//   1) function - the stitched netlist tracks the golden RTL model
//      step for step;
//   2) masking - forcing ONE replica's output wrong for many cycles
//      never disturbs the voted stream (2-of-3 holds);
//   3) heal - the moment the force releases, the replica rejoins and
//      the divergence disappears, because its own D path reads the
//      VOTED value (the self-correcting feedback, now tool-applied).
`default_nettype none
`timescale 1ns/1ps
module tb_tmr_stitch;
  reg clk = 0, rst_n = 0;
  always #20 clk = ~clk;

  wire [15:0] q_dut;
  tmr_carrier dut (.clk(clk), .rst_n(rst_n), .q_o(q_dut));

  // golden RTL model
  reg [15:0] gold;
  always @(posedge clk) begin
    if (!rst_n) gold <= 16'hACE1;
    else        gold <= {gold[14:0], gold[15] ^ gold[13] ^ gold[12] ^ gold[10]};
  end

  integer i, errs = 0;
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1;

    // 1) function
    for (i = 0; i < 200; i = i + 1) begin
      @(negedge clk);
      if (q_dut !== gold) begin
        $display("FAIL: stitched netlist diverged clean at step %0d (%h vs %h)",
                 i, q_dut, gold); errs = errs + 1; i = 200;
      end
    end
    if (errs == 0) $display("  ok: stitched netlist tracks the golden model");

    // 2) masking: pin replica B of flop 5 wrong for 100 cycles
    force dut.tmrB_5 = 1'b1;
    for (i = 0; i < 100; i = i + 1) begin
      @(negedge clk);
      if (q_dut !== gold) begin
        $display("FAIL: forced replica reached the output at step %0d", i);
        errs = errs + 1; i = 100;
      end
    end
    if (errs == 0) $display("  ok: one pinned replica never disturbed the vote");

    // 3) heal: release and the stream must stay clean AND the replica
    //    must rejoin (its D reads the voted net)
    release dut.tmrB_5;
    @(negedge clk); @(negedge clk);
    for (i = 0; i < 100; i = i + 1) begin
      @(negedge clk);
      if (q_dut !== gold) begin
        $display("FAIL: post-release divergence at step %0d", i);
        errs = errs + 1; i = 100;
      end
    end
    if (dut.tmrB_5 !== dut.tmrA_5) begin
      $display("FAIL: replica never rejoined after release");
      errs = errs + 1;
    end
    if (errs == 0) $display("  ok: replica rejoined - voted feedback heals");

    if (errs == 0) $display("TMRSTITCH: PASS (function, mask, heal)");
    else begin $display("TMRSTITCH: FAIL (%0d)", errs); $fatal(1); end
    $finish;
  end
  initial begin #1_000_000; $display("FAIL: tmr stitch bench hung"); $fatal(1); end
endmodule
`default_nettype wire
