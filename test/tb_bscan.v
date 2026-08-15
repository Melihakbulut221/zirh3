// ZIRH-3 - boundary scan through the flight lock (F28):
// SAMPLE reads the die's pins through the TAP without disturbing them;
// EXTEST drives the output pins from the shift chain - but only when
// the flight fuse permits. Locked, the same EXTEST lands on deaf pins:
// the boundary cells obey the one absorbing lock that guards halt and
// SBA. Board-level interconnect test on the bench, an untouchable pin
// ring in flight.
`default_nettype none
`timescale 1ns/1ps
module tb_bscan;
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

  localparam [4:0] IR_EXTEST = 5'h00, IR_SAMPLE = 5'h02,
                   IR_BYPASS = 5'h1f;

  // BSR cells: [0] rst_n_pad [1] pwr_good [2] boot_strap [3] dbg_unlock
  //            [4] uart_rx [5] uart_tx [6] sys_rst_n [7] boot_sel
  //            [8] evt_accept [9] evt_reject [10] dbg_locked [11] err

  integer errs = 0;
  reg [63:0] r;

  task power_up(input unlock); begin
    dbg_unlock = unlock; boot_strap = 0;
    trst_n = 0; rst_n_pad = 0;
    repeat (6) @(posedge clk);
    trst_n = 1; rst_n_pad = 1;
    repeat (80) @(posedge clk);   // POR settle, fuse sampled
    tap_reset;
  end endtask

  initial begin
    // 1) SAMPLE on the unlocked, idle die: the captured boundary must
    //    show the real pins - resets released, UART lines idle high,
    //    no boot, no error
    power_up(1'b1);
    load_ir(IR_SAMPLE);
    shift_dr(12, 64'd0, r);
    if (r[0]  !== 1'b1) begin $display("FAIL: sample rst_n_pad != 1");  errs=errs+1; end
    if (r[1]  !== 1'b1) begin $display("FAIL: sample pwr_good != 1");   errs=errs+1; end
    if (r[4]  !== 1'b1) begin $display("FAIL: sample uart_rx != 1");    errs=errs+1; end
    if (r[5]  !== 1'b1) begin $display("FAIL: sample uart_tx != 1");    errs=errs+1; end
    if (r[6]  !== 1'b1) begin $display("FAIL: sample sys_rst_n != 1");  errs=errs+1; end
    if (r[7]  !== 1'b0) begin $display("FAIL: sample boot_sel != 0");   errs=errs+1; end
    if (r[10] !== 1'b0) begin $display("FAIL: sample dbg_locked != 0"); errs=errs+1; end
    if (r[11] !== 1'b0) begin
      $display("FAIL: sample err != 0 (r=%b)", r[11:0]);
      $display("  dbg: err_int=%b bl=%b jtag=%b gate=%b clkobs=%b soc=%b bank=%b hk=%b tlm=%b mb=%b",
        dut.err_int, dut.bl_err, dut.jtag_err, dut.gate_err, dut.clkobs_err,
        dut.soc_err, dut.bank_err, dut.hk_infra, dut.tlm_err, dut.mb_err);
      errs=errs+1;
    end
    if (errs == 0) $display("  ok: SAMPLE read the real pins through the TAP");

    // 2) EXTEST unlocked: preload a pattern, the output pins follow the
    //    chain - uart_tx dragged low, boot_sel dragged high, from outside
    load_ir(IR_SAMPLE);                    // PRELOAD the drive pattern
    shift_dr(12, {52'd0, 12'b0_0_0_0_1_0_0_0_0000}, r);  // boot_sel cell only
    load_ir(IR_EXTEST);
    #200;
    if (uart_tx !== 1'b0) begin
      $display("FAIL: EXTEST did not drive uart_tx low (preload 0)");
      errs = errs + 1;
    end else $display("  ok: EXTEST drove uart_tx from the chain");
    if (boot_sel !== 1'b1) begin
      $display("FAIL: EXTEST did not drive boot_sel high");
      errs = errs + 1;
    end else $display("  ok: EXTEST drove boot_sel from the chain");
    load_ir(IR_BYPASS);                    // release the pins
    #200;
    if (uart_tx !== 1'b1) begin
      $display("FAIL: pins did not return to functional after EXTEST");
      errs = errs + 1;
    end

    // 3) LOCKED: the same preload + EXTEST must land on deaf pins
    power_up(1'b0);
    if (dbg_locked !== 1'b1) begin $display("FAIL: fuse clear but not locked"); errs=errs+1; end
    load_ir(IR_SAMPLE);
    shift_dr(12, {52'd0, 12'b0_0_0_0_1_0_0_0_0000}, r);
    load_ir(IR_EXTEST);
    #200;
    if (uart_tx !== 1'b1 || boot_sel !== 1'b0) begin
      $display("FAIL: locked die let EXTEST wiggle a pin (tx=%b sel=%b)",
               uart_tx, boot_sel);
      errs = errs + 1;
    end else $display("  ok: locked gate held the boundary cells inert");

    if (errs == 0) $display("BSCAN_SMOKE: PASS (sample, extest, locked inert)");
    else begin $display("BSCAN_SMOKE: FAIL (%0d)", errs); $fatal(1); end
    $finish;
  end
  initial begin #20_000_000; $display("FAIL: bscan smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
