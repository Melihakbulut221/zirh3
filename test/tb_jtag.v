// ZIRH-3 - JTAG debug module smoke: shift IDCODE out and check it, then
// write dmcontrol.haltreq over DMI and confirm the halt request reaches
// the gate ONLY when the flight fuse permits debug - locked by default,
// live when unlocked. The whole point of F27: a debug port that is inert
// in flight and works on the bench.
`default_nettype none
`timescale 1ns/1ps
module tb_jtag;
  reg tck = 0, tms = 0, tdi = 0, trst_n = 0;
  wire tdo;
  reg clk = 0, rst_n = 0;
  reg core_halted = 0;
  reg unlock_strap = 0;

  always #20 clk = ~clk;

  // DM -> gate
  wire dm_req, dm_ndm, dm_sba_cyc, dm_sba_we;
  wire [31:0] dm_sba_adr, dm_sba_dat;
  wire dm_err;
  zirh_jtag_dm u_dm (
    .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo), .trst_n(trst_n),
    .clk(clk), .rst_n(rst_n), .core_halted_i(core_halted),
    .dm_debug_req_o(dm_req), .dm_ndmreset_o(dm_ndm),
    .dm_sba_cyc_o(dm_sba_cyc), .dm_sba_adr_o(dm_sba_adr),
    .dm_sba_dat_o(dm_sba_dat), .dm_sba_we_o(dm_sba_we),
    .sba_rdt_i(32'h0), .sba_ack_i(1'b0),
    .bs_cap_i(12'd0), .bs_drv_o(), .bs_extest_o(),
    .err_o(dm_err));

  // the proven isolation gate, exactly as it sits on the die
  wire gated_req, gated_ndm, gated_cyc, locked, gate_err;
  zirh_dbg_gate u_gate (
    .clk(clk), .rst_n(rst_n), .unlock_strap_i(unlock_strap),
    .dm_debug_req_i(dm_req), .dm_ndmreset_i(dm_ndm),
    .dm_sba_cyc_i(dm_sba_cyc), .dm_sba_adr_i(dm_sba_adr),
    .dm_sba_dat_i(dm_sba_dat), .dm_sba_we_i(dm_sba_we),
    .debug_req_o(gated_req), .ndmreset_o(gated_ndm),
    .sba_cyc_o(gated_cyc), .sba_adr_o(), .sba_dat_o(), .sba_we_o(),
    .locked_o(locked), .err_o(gate_err));

  // --- JTAG primitives ------------------------------------------------------
  task tck_pulse(input t);
    begin tms = t; #100 tck = 1; #100 tck = 0; end
  endtask

  // move to TEST_LOGIC_RESET then RUN_TEST_IDLE
  task tap_reset;
    integer i;
    begin
      for (i = 0; i < 6; i = i + 1) tck_pulse(1'b1);  // -> TLR
      tck_pulse(1'b0);                                 // -> RUN_TEST_IDLE
    end
  endtask

  // load a 5-bit instruction into IR
  task load_ir(input [4:0] instr);
    integer i;
    begin
      tck_pulse(1'b1);          // Select-DR
      tck_pulse(1'b1);          // Select-IR
      tck_pulse(1'b0);          // Capture-IR
      tck_pulse(1'b0);          // Shift-IR
      for (i = 0; i < 5; i = i + 1) begin
        tdi = instr[i];
        tck_pulse(i == 4 ? 1'b1 : 1'b0);   // last bit exits to Exit1-IR
      end
      tck_pulse(1'b1);          // Update-IR
      tck_pulse(1'b0);          // Run-Test/Idle
    end
  endtask

  // shift a DR of `n` bits, sending `sendv`, capturing into `capt`.
  // tms is set BEFORE each rising edge (the edge the TAP samples); the
  // final bit carries tms=1 to leave Shift-DR for Exit1-DR.
  task shift_dr(input integer n, input [63:0] sendv, output [63:0] capt);
    integer i;
    begin
      capt = 64'd0;
      tck_pulse(1'b1);          // Select-DR
      tck_pulse(1'b0);          // Capture-DR
      tck_pulse(1'b0);          // Shift-DR (now IN Shift-DR)
      for (i = 0; i < n; i = i + 1) begin
        tdi = sendv[i];
        tms = (i == n - 1) ? 1'b1 : 1'b0;   // last bit exits to Exit1-DR
        #100 tck = 1; #40 capt[i] = tdo; #60 tck = 0;
      end
      tck_pulse(1'b1);          // Update-DR
      tck_pulse(1'b0);          // Run-Test/Idle
    end
  endtask

  // a DMI write: {addr[6:0], data[31:0], op[1:0]}, 41 bits
  task dmi_write(input [6:0] a, input [31:0] d);
    reg [63:0] junk;
    begin
      load_ir(5'h11);           // IR = DMI
      shift_dr(41, {23'd0, a, d, 2'd2}, junk);
    end
  endtask

  reg [3:0] ptap; 
  always @(posedge tck) if (u_dm.tap==4'h8) $display("PROBE Update-DR ir=%02x dr40=%011x", u_dm.ir, u_dm.dr[40:0]);
  integer errs = 0;
  reg [63:0] cap;
  initial begin
    trst_n = 0; rst_n = 0;
    #200 trst_n = 1; rst_n = 1;
    repeat (4) @(posedge clk);

    // 1) IDCODE shifts out correctly
    tap_reset;
    load_ir(5'h01);             // IDCODE
    shift_dr(32, 64'd0, cap);
    if (cap[31:0] !== 32'h05A300001) begin
      $display("FAIL: IDCODE = %08x, expected 05A300001", cap[31:0]);
      errs = errs + 1;
    end else $display("  ok: IDCODE = %08x", cap[31:0]);

    // 2) locked by default: a haltreq write must NOT reach the core
    unlock_strap = 0;
    dmi_write(7'h10, 32'h8000_0001);   // haltreq | dmactive
    repeat (20) @(posedge clk);
    if (dm_req !== 1'b1) begin $display("FAIL: DM did not raise haltreq"); errs = errs + 1; end
    if (gated_req !== 1'b0) begin
      $display("FAIL: locked gate let haltreq through (gated_req=%b)", gated_req);
      errs = errs + 1;
    end else $display("  ok: locked gate holds haltreq inert (DM asked, gate refused)");
    if (locked !== 1'b1) begin $display("FAIL: gate not locked by default"); errs = errs + 1; end

    // 3) unlocked at the fuse: the same request now reaches the core
    // (the fuse is sampled at POR - re-pulse reset with the strap high)
    unlock_strap = 1;
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
    repeat (6) @(posedge clk);
    dmi_write(7'h10, 32'h8000_0001);
    repeat (20) @(posedge clk);
    if (gated_req !== 1'b1) begin
      $display("FAIL: unlocked gate blocked haltreq (gated_req=%b)", gated_req);
      errs = errs + 1;
    end else $display("  ok: unlocked gate passes haltreq to the core");

    if (dm_err === 1'b1 || gate_err === 1'b1) begin
      $display("FAIL: spurious TMR error (dm=%b gate=%b)", dm_err, gate_err);
      errs = errs + 1;
    end

    if (errs == 0) $display("JTAG_SMOKE: PASS (IDCODE, locked-inert, unlocked-live)");
    else begin $display("JTAG_SMOKE: FAIL (%0d)", errs); $fatal(1); end
    $finish;
  end
  initial begin #5_000_000; $display("FAIL: jtag smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
