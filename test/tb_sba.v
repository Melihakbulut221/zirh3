// ZIRH-3 - System Bus Access through the gate (import ladder rung 5):
// a JTAG debugger writes and reads the sliced bank WITHOUT halting the
// core - but only when the flight fuse permits. Unlocked: the poke lands
// and reads back. Locked: the gate holds the whole SBA master inert, so
// the bank never sees the access. Peek/poke that is live on the bench
// and impossible in flight.
`default_nettype none
`timescale 1ns/1ps
module tb_sba;
  reg clk = 0, rst_n_pad = 0, pwr_good = 1;
  reg boot_strap = 0, dbg_unlock = 0;
  reg uart_rx = 1;
  reg tck = 0, tms = 0, tdi = 0, trst_n = 0;
  wire tdo, sys_rst_n, boot_sel, dbg_locked, err, uart_tx;

  always #20 clk = ~clk;

  zirh3_top #(.POR_CYCLES(16), .RESET_DIV(174)) dut (
    .clk(clk), .rst_n_pad(rst_n_pad), .pwr_good_i(pwr_good),
    .boot_strap_i(boot_strap), .dbg_unlock_strap_i(dbg_unlock),
    .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
    .tck_i(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo), .trst_n_i(trst_n),
    .sys_rst_n_o(sys_rst_n), .boot_sel_o(boot_sel),
    .evt_boot_accept_o(), .evt_boot_reject_o(),
    .dbg_locked_o(dbg_locked), .err_o(err));

  // --- JTAG primitives (TCK domain) ----------------------------------------
  task tck_pulse(input t); begin tms = t; #100 tck = 1; #100 tck = 0; end endtask
  task tap_reset; integer i; begin
    for (i = 0; i < 6; i = i + 1) tck_pulse(1'b1);
    tck_pulse(1'b0);
  end endtask
  task load_ir(input [4:0] instr); integer i; begin
    tck_pulse(1'b1); tck_pulse(1'b1); tck_pulse(1'b0); tck_pulse(1'b0);
    for (i = 0; i < 5; i = i + 1) begin tdi = instr[i]; tck_pulse(i==4?1'b1:1'b0); end
    tck_pulse(1'b1); tck_pulse(1'b0);
  end endtask
  task shift_dr(input integer n, input [63:0] sendv, output [63:0] capt);
    integer i; begin
    capt = 64'd0;
    tck_pulse(1'b1); tck_pulse(1'b0); tck_pulse(1'b0);
    for (i = 0; i < n; i = i + 1) begin
      tdi = sendv[i]; tms = (i==n-1)?1'b1:1'b0;
      #100 tck = 1; #40 capt[i] = tdo; #60 tck = 0;
    end
    tck_pulse(1'b1); tck_pulse(1'b0);
  end endtask

  // DMI op: 1=read, 2=write. Payload {addr[6:0], data[31:0], op[1:0]}.
  task dmi(input [6:0] a, input [31:0] d, input [1:0] op, output [63:0] resp);
    begin load_ir(5'h11); shift_dr(41, {23'd0, a, d, op}, resp); end
  endtask

  localparam [6:0] SBCS = 7'h38, SBADDR = 7'h39, SBDATA = 7'h3c;

  integer errs = 0;
  reg [63:0] r;
  reg [31:0] readback;

  // read bank[0] over SBA: sbreadonaddr=1, write sbaddress (launch read),
  // let it complete, then DMI-read sbdata0
  task sba_read(input [31:0] addr, output [31:0] val);
    begin
      dmi(SBCS,   32'h0010_0000, 2'd2, r);   // sbreadonaddr (bit 20)
      dmi(SBADDR, addr,          2'd2, r);   // launch the read
      repeat (40) @(posedge clk);
      dmi(SBDATA, 32'd0,         2'd1, r);   // DMI read op -> resp on next
      dmi(SBDATA, 32'd0,         2'd1, r);   // capture the response
      val = r[33:2];
    end
  endtask

  task sba_write(input [31:0] addr, input [31:0] data);
    begin
      dmi(SBCS,   32'h0000_0000, 2'd2, r);   // sbreadonaddr off
      dmi(SBADDR, addr,          2'd2, r);   // set address
      dmi(SBDATA, data,          2'd2, r);   // write launches the bus write
      repeat (40) @(posedge clk);
    end
  endtask

  task power_up(input unlock); begin
    dbg_unlock = unlock; boot_strap = 0;
    trst_n = 0; rst_n_pad = 0;
    repeat (6) @(posedge clk);
    trst_n = 1; rst_n_pad = 1;
    repeat (80) @(posedge clk);   // POR settle, fuse sampled
    tap_reset;
  end endtask

  initial begin
    // 1) UNLOCKED: SBA poke lands and reads back
    power_up(1'b1);
    if (dbg_locked !== 1'b0) begin $display("FAIL: fuse set but still locked"); errs=errs+1; end
    sba_write(32'h0000_4000, 32'h0000_BEEF);
    sba_read (32'h0000_4000, readback);
    if (readback !== 32'h0000_BEEF) begin
      $display("FAIL: unlocked SBA readback = %08x, expected 0000BEEF", readback);
      errs = errs + 1;
    end else $display("  ok: unlocked debugger peeked/poked the bank (BEEF)");

    // 2) LOCKED: the same poke must NOT reach the bank
    power_up(1'b0);
    if (dbg_locked !== 1'b1) begin $display("FAIL: fuse clear but not locked"); errs=errs+1; end
    // first prove the cell is clean (unlock, read, relock would disturb;
    // instead write a known value while unlocked, then relock and try to
    // overwrite it locked)
    power_up(1'b1);
    sba_write(32'h0000_4004, 32'h0000_1234);   // seed word 1 unlocked
    power_up(1'b0);                            // relock
    sba_write(32'h0000_4004, 32'h0000_FFFF);   // attempt overwrite, locked
    power_up(1'b1);                            // unlock to observe
    sba_read (32'h0000_4004, readback);
    if (readback !== 32'h0000_1234) begin
      $display("FAIL: locked SBA reached the bank (word1 = %08x, expected 1234)", readback);
      errs = errs + 1;
    end else $display("  ok: locked gate held the SBA inert (seed survived)");

    if (err === 1'b1) begin $display("FAIL: spurious TMR error"); errs=errs+1; end

    if (errs == 0) $display("SBA_SMOKE: PASS (unlocked peek/poke, locked inert)");
    else begin $display("SBA_SMOKE: FAIL (%0d)", errs); $fatal(1); end
    $finish;
  end
  initial begin #20_000_000; $display("FAIL: sba smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
