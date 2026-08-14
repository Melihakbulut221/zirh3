// =============================================================================
// ZIRH - boot-controller scenario suite in SystemVerilog
// test/sv/zirh_boot_scenarios_tb.sv
//
// The flight stories the boot contract must survive, each as a
// scenario against the real zirh_boot_ctrl with a behavioral bank
// memory that can be made to LIE - because the controller's
// distinctive claim is that it CRCs what the memory actually stored,
// not what went over the wire, and only a lying memory can test that.
//
//   make -C test -f Makefile.svs boot            # all 8 scenarios
//
// Scenarios:
//   golden_strap   strap 00: no loader, ROM fetch, forever
//   good_image     strap 01: valid image streams, commits, bank runs
//   bad_magic      wrong magic word: refused at the header
//   bad_crc        wire CRC wrong: refused after readback
//   oversize       header length past the bank: refused at the header
//   truncated      stream dies mid-payload: no commit, and a fresh POR
//                  finds a working controller (a half-load must not
//                  brick anything)
//   storage_lie    stream is perfect, the MEMORY corrupts one stored
//                  word: VERIFY must catch it - the read-back-CRC
//                  claim, tested at the only boundary that can test it
//   wd_revert      committed image never signs on, watchdog fails it:
//                  the ladder falls back and the bank is abandoned
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module zirh_boot_scenarios_tb;

  localparam integer BANK_WORDS = 64;   // small banks, fast scenarios
  localparam [31:0]  MAGIC = 32'h5A495248;

  reg         clk;
  reg         rst_n;
  reg  [1:0]  strap;
  reg         st_valid;
  reg  [7:0]  st_data;
  wire        st_ready;
  reg         sig_ok;
  reg         signon;
  reg         wd_fail;
  wire        m_cyc;
  wire [31:0] m_adr;
  wire [31:0] m_dat;
  wire        m_we;
  reg  [31:0] m_rdt;
  reg         m_ack;
  wire        boot_sel;
  wire        bank;
  wire        evt_accept;
  wire        evt_reject;
  wire        err;

  zirh_boot_ctrl #(.BANK_WORDS(BANK_WORDS)) dut (
    .clk(clk), .rst_n(rst_n), .strap_i(strap),
    .st_valid_i(st_valid), .st_data_i(st_data), .st_ready_o(st_ready),
    .sig_ok_i(sig_ok), .signon_i(signon), .wd_fail_i(wd_fail),
    .m_cyc_o(m_cyc), .m_adr_o(m_adr), .m_dat_o(m_dat), .m_we_o(m_we),
    .m_rdt_i(m_rdt), .m_ack_i(m_ack),
    .boot_sel_o(boot_sel), .bank_o(bank),
    .evt_accept_o(evt_accept), .evt_reject_o(evt_reject), .err_o(err));

  always #20 clk = ~clk;

  // ------------------------------------------------- lying-capable bank RAM
  reg [31:0] mem [0:2*BANK_WORDS-1];
  integer    lie_addr;      // word index to corrupt on write, -1 = honest

  always @(posedge clk) begin
    m_ack <= 1'b0;
    if (m_cyc && !m_ack) begin
      if (m_we)
        mem[m_adr[31:2]] <= (m_adr[31:2] == lie_addr[31:0])
                            ? (m_dat ^ 32'h0000_0100)   // the stored lie
                            : m_dat;
      else
        m_rdt <= mem[m_adr[31:2]];
      m_ack <= 1'b1;
    end
  end

  // ------------------------------------------------------------ bookkeeping
  integer checks_done, scenarios_run;
  reg [8*16-1:0] cur_scn;

  task check(input cond, input [8*64-1:0] what);
    begin
      checks_done = checks_done + 1;
      if (!cond) begin
        $display("FAIL [%0s] %0s at %0t", cur_scn, what, $time);
        $fatal(1);
      end
    end
  endtask

  // ------------------------------------------------------------------ image
  function [31:0] crc32_byte(input [31:0] c, input [7:0] b);
    integer i;
    reg [31:0] x;
    begin
      x = c ^ {24'h0, b};
      for (i = 0; i < 8; i = i + 1)
        x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
      crc32_byte = x;
    end
  endfunction

  localparam integer IMG_WORDS = 8;
  reg [7:0] blob [0:11 + 4*IMG_WORDS];
  integer   blob_len;

  // build header+payload; the payload is a recognizable ramp
  task build_image(input [31:0] magic, input [15:0] len,
                   input use_good_crc, input [31:0] forced_crc);
    integer i, w;
    reg [31:0] crc;
    reg [31:0] word;
    begin
      crc = 32'hFFFF_FFFF;
      for (w = 0; w < IMG_WORDS; w = w + 1) begin
        word = 32'hB007_0000 | w[15:0];
        for (i = 0; i < 4; i = i + 1) begin
          blob[12 + 4*w + i] = word[8*i +: 8];
          crc = crc32_byte(crc, word[8*i +: 8]);
        end
      end
      crc = ~crc;
      if (!use_good_crc) crc = forced_crc;
      for (i = 0; i < 4; i = i + 1) blob[i]     = magic[8*i +: 8];
      for (i = 0; i < 2; i = i + 1) blob[4 + i] = len[8*i +: 8];
      blob[6] = 8'h01; blob[7] = 8'h00;             // version 1
      for (i = 0; i < 4; i = i + 1) blob[8 + i] = crc[8*i +: 8];
      blob_len = 12 + 4*IMG_WORDS;
    end
  endtask

  // stream the blob; stop early on a ruling or at stop_at bytes
  integer acc_seen, rej_seen;
  task stream(input integer stop_at, input integer timeout);
    integer i, t;
    begin
      acc_seen = 0; rej_seen = 0; i = 0; t = 0;
      while (i < stop_at && t < timeout) begin
        st_valid = 1'b1;
        st_data  = blob[i];
        @(posedge clk);
        #1;
        if (st_ready) i = i + 1;
        acc_seen = acc_seen + evt_accept;
        rej_seen = rej_seen + evt_reject;
        if (acc_seen + rej_seen > 0) t = timeout + 7;
        t = t + 1;
      end
      st_valid = 1'b0;
      // rulings can land a few cycles after the last byte
      for (t = 0; t < 6 * 4 * (IMG_WORDS + 4); t = t + 1) begin
        @(posedge clk);
        #1;
        acc_seen = acc_seen + evt_accept;
        rej_seen = rej_seen + evt_reject;
      end
    end
  endtask

  task por(input [1:0] s);
    begin
      st_valid = 1'b0; st_data = 8'h00; sig_ok = 1'b1;
      signon = 1'b0; wd_fail = 1'b0; strap = s; lie_addr = -1;
      rst_n = 1'b0;
      repeat (5) @(posedge clk);
      rst_n = 1'b1;
      repeat (5) @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------------- scenarios
  task scn_golden_strap;
    begin
      cur_scn = "golden_strap"; por(2'b00);
      repeat (200) @(posedge clk);
      check(boot_sel === 1'b0, "golden strap must fetch ROM");
      check(err === 1'b0, "loader TMR error at rest");
    end
  endtask

  task scn_good_image;
    begin
      cur_scn = "good_image"; por(2'b01);
      build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
      stream(blob_len, 200_000);
      check(acc_seen == 1 && rej_seen == 0, "valid image must commit");
      check(boot_sel === 1'b1, "committed image must run from SRAM");
      check(bank === 1'b0, "strap 01 must land in bank A");
      check(mem[0] === 32'hB007_0000, "word 0 must be stored verbatim");
    end
  endtask

  task scn_bad_magic;
    begin
      cur_scn = "bad_magic"; por(2'b01);
      build_image(32'h4B41_5A52, IMG_WORDS[15:0], 1'b1, 32'h0);
      stream(blob_len, 200_000);
      check(rej_seen == 1 && acc_seen == 0, "wrong magic must be refused");
      check(boot_sel === 1'b0, "refused image must leave ROM in charge");
    end
  endtask

  task scn_bad_crc;
    begin
      cur_scn = "bad_crc"; por(2'b01);
      build_image(MAGIC, IMG_WORDS[15:0], 1'b0, 32'hDEAD_BEEF);
      stream(blob_len, 200_000);
      check(rej_seen == 1 && acc_seen == 0, "wrong CRC must be refused");
      check(boot_sel === 1'b0, "refused image must leave ROM in charge");
    end
  endtask

  task scn_oversize;
    begin
      cur_scn = "oversize"; por(2'b01);
      build_image(MAGIC, BANK_WORDS[15:0], 1'b1, 32'h0);  // > BANK_WORDS-3
      stream(blob_len, 200_000);
      check(rej_seen == 1 && acc_seen == 0, "oversize length must be refused");
    end
  endtask

  task scn_truncated;
    begin
      cur_scn = "truncated"; por(2'b01);
      build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
      stream(blob_len - 7, 200_000);       // die mid-payload
      check(acc_seen == 0, "half an image must never commit");
      check(boot_sel === 1'b0, "half an image must not leave ROM");
      // and the controller is not bricked: a fresh POR loads fine
      por(2'b01);
      build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
      stream(blob_len, 200_000);
      check(acc_seen == 1, "controller bricked by an interrupted load");
    end
  endtask

  task scn_storage_lie;
    begin
      cur_scn = "storage_lie"; por(2'b01);
      lie_addr = 3;                        // memory corrupts stored word 3
      build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
      stream(blob_len, 200_000);
      check(rej_seen == 1 && acc_seen == 0,
            "VERIFY must CRC the STORED image, not the wire");
      check(boot_sel === 1'b0, "a lying bank must never be run");
    end
  endtask

  task scn_wd_revert;
    integer n;
    begin
      cur_scn = "wd_revert"; por(2'b01);
      build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
      stream(blob_len, 200_000);
      check(acc_seen == 1, "precondition: image must commit");
      check(boot_sel === 1'b1, "precondition: bank must run");
      // no signon ever arrives; the watchdog rules
      wd_fail = 1'b1;
      @(posedge clk);
      wd_fail = 1'b0;
      n = 0;
      while (n < 200 && boot_sel !== 1'b0) begin @(posedge clk); n = n + 1; end
      check(boot_sel === 1'b0,
            "watchdog-failed image must fall back off the bank");
    end
  endtask

  // ------------------------------------------------------------------ runner
  reg [8*16-1:0] want_scn;
  reg run_all;

  task run_one(input [8*16-1:0] name);
    begin
      if (run_all || want_scn == name) begin
        scenarios_run = scenarios_run + 1;
        case (name)
          "golden_strap": scn_golden_strap;
          "good_image":   scn_good_image;
          "bad_magic":    scn_bad_magic;
          "bad_crc":      scn_bad_crc;
          "oversize":     scn_oversize;
          "truncated":    scn_truncated;
          "storage_lie":  scn_storage_lie;
          "wd_revert":    scn_wd_revert;
        endcase
        $display("PASS [%0s] (%0d checks so far)", name, checks_done);
      end
    end
  endtask

  initial begin
    clk = 1'b0; checks_done = 0; scenarios_run = 0; m_ack = 1'b0;
    m_rdt = 32'h0; lie_addr = -1;
    run_all = !$value$plusargs("SCENARIO=%s", want_scn);

    run_one("golden_strap");
    run_one("good_image");
    run_one("bad_magic");
    run_one("bad_crc");
    run_one("oversize");
    run_one("truncated");
    run_one("storage_lie");
    run_one("wd_revert");

    if (scenarios_run == 0) begin
      $display("FAIL: unknown scenario +SCENARIO=%0s", want_scn);
      $fatal(1);
    end
    $display("SV_BOOT_SCENARIOS: PASS scenarios=%0d checks=%0d",
             scenarios_run, checks_done);
    $finish;
  end

  initial begin
    #400_000_000;   // 10M cycles - far past every scenario
    $display("FAIL [%0s] bench watchdog: scenario hung", cur_scn);
    $fatal(1);
  end

endmodule

`default_nettype wire
