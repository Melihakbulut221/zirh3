// ZIRH-3 - the new core's first breath (Cycle 14 rung 1).
// VexRiscv_Lite through zirh_vex_wrap against a bare unified memory:
// fetch runs, stores land, a load round-trips, and one MUL proves the
// M extension is real - the four things the soc swap will lean on.
// The program is hand-assembled below; the memory model acks in one
// cycle like every slave on the real bus.
`default_nettype none
`timescale 1ns/1ps
module tb_vex;
  reg clk = 0, rst_n = 0;
  always #20 clk = ~clk;

  wire [31:0] iadr, irdt, dadr, ddat, drdt;
  wire [3:0]  dsel;
  wire        icyc, dcyc, dwe;
  reg         iack = 0, dack = 0;

  zirh_vex_wrap dut (
    .clk(clk), .rst_n(rst_n), .timer_irq_i(1'b0),
    .reset_vector_i(32'h0000_0000),
    .ibus_adr_o(iadr), .ibus_cyc_o(icyc), .ibus_rdt_i(irdt), .ibus_ack_i(iack),
    .dbus_adr_o(dadr), .dbus_dat_o(ddat), .dbus_sel_o(dsel),
    .dbus_we_o(dwe), .dbus_cyc_o(dcyc), .dbus_rdt_i(drdt), .dbus_ack_i(dack));

  // 4 KB unified memory, 1-cycle registered ack on both ports
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
    for (i = 0; i < 1024; i = i + 1) mem[i] = 32'h0000_006F; // jal x0,0
    // the program: store a byte pattern, multiply, read back, derive
    mem[0] = 32'h05A00313;   // addi x6, x0, 0x5A
    mem[1] = 32'h10602023;   // sw   x6, 256(x0)
    mem[2] = 32'h00700513;   // addi x10, x0, 7
    mem[3] = 32'h00600593;   // addi x11, x0, 6
    mem[4] = 32'h02B503B3;   // mul  x7, x10, x11        (= 42, M ext)
    mem[5] = 32'h10702223;   // sw   x7, 260(x0)
    mem[6] = 32'h10002E03;   // lw   x28, 256(x0)
    mem[7] = 32'h001E0E13;   // addi x28, x28, 1         (= 0x5B)
    mem[8] = 32'h11C02423;   // sw   x28, 264(x0)
    mem[9] = 32'h0000006F;   // jal  x0, 0               (park)

    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (400) @(posedge clk);

    if (mem[64] !== 32'h0000005A) begin
      $display("FAIL: store never landed (mem[0x100]=%08x)", mem[64]); errs=errs+1;
    end else $display("  ok: fetch ran and the store landed (0x5A)");
    if (mem[65] !== 32'd42) begin
      $display("FAIL: MUL wrong (mem[0x104]=%08x, want 42)", mem[65]); errs=errs+1;
    end else $display("  ok: M extension is real (7*6=42)");
    if (mem[66] !== 32'h0000005B) begin
      $display("FAIL: load roundtrip broke (mem[0x108]=%08x)", mem[66]); errs=errs+1;
    end else $display("  ok: load round-tripped and derived (0x5B)");

    if (errs == 0) $display("VEX_SMOKE: PASS (fetch, store, mul, load)");
    else begin $display("VEX_SMOKE: FAIL (%0d)", errs); $fatal(1); end
    $finish;
  end
  initial begin #2_000_000; $display("FAIL: vex smoke hung"); $fatal(1); end
endmodule
`default_nettype wire
