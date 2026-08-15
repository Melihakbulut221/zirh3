// ZIRH-3 - triple-core lockstep under fire (Cycle 14 rung 3, pilot A).
// Three cores run the same store loop behind the voted bus; the bench
// then reaches into ONE core's register file and flips a bit - the
// SEU model at the coarsest grain. The claim under test: the memory
// never sees a wrong write (the two clean cores outvote the corrupted
// one), and the divergence flag latches sticky so the fabric can
// count and recover. Also the candidate's honest limit, asserted as
// such: the diverged core does NOT come back by itself.
`default_nettype none
`timescale 1ns/1ps
module tb_vex_tmr;
  reg clk = 0, rst_n = 0;
  always #20 clk = ~clk;

  wire [31:0] iadr, irdt, dadr, ddat, drdt;
  wire [3:0]  dsel;
  wire        icyc, dcyc, dwe, err;
  reg         iack = 0, dack = 0;

  zirh_vex_tmr dut (
    .clk(clk), .rst_n(rst_n), .timer_irq_i(1'b0),
    .reset_vector_i(32'h0000_0000),
    .ibus_adr_o(iadr), .ibus_cyc_o(icyc), .ibus_rdt_i(irdt), .ibus_ack_i(iack),
    .dbus_adr_o(dadr), .dbus_dat_o(ddat), .dbus_sel_o(dsel),
    .dbus_we_o(dwe), .dbus_cyc_o(dcyc), .dbus_rdt_i(drdt), .dbus_ack_i(dack),
    .err_o(err));

  reg [31:0] mem [0:1023];
  assign irdt = mem[iadr[11:2]];
  assign drdt = mem[dadr[11:2]];
  always @(posedge clk) begin
    iack <= icyc & ~iack;
    dack <= dcyc & ~dack;
    if (dcyc & dwe & dack) begin
      if (dsel[0]) mem[dadr[11:2]][7:0]   <= ddat[7:0];
      if (dsel[1]) mem[dadr[11:2]][15:8]  <= ddat[15:8];
      if (dsel[2]) mem[dadr[11:2]][23:16] <= ddat[23:16];
      if (dsel[3]) mem[dadr[11:2]][31:24] <= ddat[31:24];
    end
  end

  integer i, errs = 0;
  initial begin
    for (i = 0; i < 1024; i = i + 1) mem[i] = 32'h0000_006F;
    mem[0] = 32'h05A00313;   // addi x6, x0, 0x5A
    mem[1] = 32'h10602023;   // sw   x6, 256(x0)
    mem[2] = 32'hFFDFF06F;   // jal  x0, -4  (store forever)

    repeat (8) @(posedge clk);
    rst_n = 1;

    // wait for the loop to prove itself
    i = 0;
    while (mem[64] !== 32'h0000005A && i < 4000) begin
      @(posedge clk); i = i + 1;
    end
    if (mem[64] !== 32'h0000005A) begin
      $display("FAIL: lockstep loop never stored"); $fatal(1);
    end
    if (err !== 1'b0) begin
      $display("FAIL: divergence flag up before any fault"); $fatal(1);
    end
    $display("  ok: three cores in lockstep, stores landing");

    // the SEU: flip bit 0 of x6 in core B only - it now wants to
    // store 0x5B forever
    dut.u_b.u_core.RegFilePlugin_regFile[6] =
        dut.u_b.u_core.RegFilePlugin_regFile[6] ^ 32'h1;

    repeat (2000) @(posedge clk);

    if (mem[64] !== 32'h0000005A) begin
      $display("FAIL: corrupted core reached memory (mem=%08x)", mem[64]);
      errs = errs + 1;
    end else $display("  ok: two clean cores outvoted the corrupted one");
    if (err !== 1'b1) begin
      $display("FAIL: divergence never flagged");
      errs = errs + 1;
    end else $display("  ok: divergence latched sticky for the fabric");

    // the honest limit: B is still diverged (no self-heal) - its next
    // store intent still differs. Documented property, not a defect.
    if (dut.u_b.u_core.RegFilePlugin_regFile[6] === 32'h0000005A) begin
      $display("FAIL: expected NO self-heal, but B recovered?");
      errs = errs + 1;
    end else $display("  ok: candidate's limit confirmed - no self-heal");

    if (errs == 0) $display("VEXTMR_SMOKE: PASS (outvote, sticky flag, no-heal)");
    else begin $display("VEXTMR_SMOKE: FAIL (%0d)", errs); $fatal(1); end
    $finish;
  end
  initial begin #4_000_000; $display("FAIL: vex tmr smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
