// =============================================================================
// ZIRH - boot-controller FUZZ storm in SystemVerilog (Cycle 26)
//
// The scenario suite tells eight curated stories; this bench tells a
// hundred UNCURATED ones. A seeded storm draws random episodes -
// good images, bad magic, bad CRCs, oversize headers, streams cut at
// random bytes, memories that lie about random words, images streamed
// through random silences, resets landing mid-load, watchdog
// failures - and holds three disciplines the whole way:
//
//   INVARIANTS  a guard watches every clock: accept and reject never
//               fire together, the loader's TMR error stays silent
//               under pure protocol abuse, and boot_sel/bank never
//               read X after reset.
//   LIVENESS    every tenth episode is a forced GOOD image that MUST
//               commit - no random history is allowed to brick the
//               loader.
//   COVERAGE    the storm counts what it drew; a kind drawn fewer
//               than three times fails the run. A thin storm proves
//               nothing (the SEU rain earned that sentence first).
//
//   make -C test -f Makefile.svs fuzz             # seed 1, 120 episodes
//   vvp ... +SEED=7 +EPISODES=500                 # a bigger storm
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module zirh_boot_fuzz_tb;

  localparam integer BANK_WORDS = 64;
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
                            ? (m_dat ^ 32'h0000_0100)
                            : m_dat;
      else
        m_rdt <= mem[m_adr[31:2]];
      m_ack <= 1'b1;
    end
  end

  // ---------------------------------------------------------------- storm rng
  integer seed, seed0;

  function integer rnd(input integer span);   // 0 .. span-1
    rnd = ($random(seed) & 32'h7fff_ffff) % span;
  endfunction

  // ------------------------------------------------------------ bookkeeping
  integer checks_done, episodes_run, commits, rejects, reverts;
  reg [8*16-1:0] cur_scn;

  task check(input cond, input [8*64-1:0] what);
    begin
      checks_done = checks_done + 1;
      if (!cond) begin
        $display("FAIL [%0s] %0s at %0t (seed %0d, episode %0d)",
                 cur_scn, what, $time, seed0, episodes_run);
        $fatal(1);
      end
    end
  endtask

  // ---------------------------------------------------- continuous invariants
  reg guards_on;
  always @(posedge clk) if (guards_on && rst_n) begin
    if (evt_accept && evt_reject) begin
      $display("FAIL [guard] accept and reject in the same cycle at %0t", $time);
      $fatal(1);
    end
    if (err !== 1'b0) begin
      $display("FAIL [guard] loader TMR error under protocol fuzz at %0t", $time);
      $fatal(1);
    end
    if (boot_sel !== 1'b0 && boot_sel !== 1'b1) begin
      $display("FAIL [guard] boot_sel went X at %0t", $time);
      $fatal(1);
    end
    if (bank !== 1'b0 && bank !== 1'b1) begin
      $display("FAIL [guard] bank went X at %0t", $time);
      $fatal(1);
    end
  end

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
      blob[6] = 8'h01; blob[7] = 8'h00;
      for (i = 0; i < 4; i = i + 1) blob[8 + i] = crc[8*i +: 8];
      blob_len = 12 + 4*IMG_WORDS;
    end
  endtask

  // stream the blob with random inter-byte silences up to max_gap
  integer acc_seen, rej_seen;
  task stream(input integer stop_at, input integer timeout,
              input integer max_gap);
    integer i, t, g;
    reg     took;
    begin
      acc_seen = 0; rej_seen = 0; i = 0; t = 0;
      while (i < stop_at && t < timeout) begin
        // Offer the byte and read ready in the SAME cycle it is
        // offered - that is what the loader's valid/ready contract
        // means. Reading ready after the edge asks about the NEXT
        // cycle, which is harmless while ready holds steady and loses
        // a byte at every 0->1 edge; the loader's ready does exactly
        // that on the host-mode re-entry, and that one unexercised
        // path is where the storm's sender had been wrong all along.
        st_valid = 1'b1;
        st_data  = blob[i];
        #1;
        took = st_ready;
        @(posedge clk);
        #1;
        if (took) begin
          i = i + 1;
          if (max_gap > 0) begin
            st_valid = 1'b0;
            // the verdict is a ONE-cycle pulse and it can land in a
            // silence: a gap loop that does not watch for it reports a
            // committed image as never-committed, which reads exactly
            // like a corrupted one
            for (g = rnd(max_gap + 1); g > 0; g = g - 1) begin
              @(posedge clk);
              #1;
              acc_seen = acc_seen + evt_accept;
              rej_seen = rej_seen + evt_reject;
            end
          end
        end
        acc_seen = acc_seen + evt_accept;
        rej_seen = rej_seen + evt_reject;
        if (acc_seen + rej_seen > 0) t = timeout + 7;
        t = t + 1;
      end
      st_valid = 1'b0;
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

  // a GOOD image must commit - the liveness probe every storm leans on
  task probe_alive;
    begin
      por(2'b01);
      build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
      stream(blob_len, 200_000, 0);
      check(acc_seen == 1 && rej_seen == 0, "liveness: good image must commit");
      check(boot_sel === 1'b1, "liveness: committed bank must run");
      commits = commits + 1;
    end
  endtask

  // ---------------------------------------------------------------- episodes
  localparam integer K_GOOD = 0, K_BADMAGIC = 1, K_BADCRC = 2,
                     K_OVERSIZE = 3, K_TRUNC = 4, K_LIE = 5,
                     K_GAPPY = 6, K_MIDPOR = 7, K_GOLDEN = 8, K_WDFAIL = 9,
                     // Cycle 44: the region the storm could not see. An
                     // audit measured 240 episodes in which bank B was
                     // never selected, host mode never strapped, the
                     // signature verdict never false and sign-on never
                     // raised - so the two-bank ladder, the ISP
                     // re-entry and the signature gate rested on a
                     // handful of hand-written cases while the storm
                     // rolled over the same half of the machine.
                     K_BANKB = 10, K_HOST = 11, K_SIGFAIL = 12,
                     K_SIGNON_RACE = 13;
  localparam integer NKINDS = 14;
  integer kind_count [0:NKINDS-1];

  task episode(input integer kind);
    integer cut, k;
    begin
      kind_count[kind] = kind_count[kind] + 1;
      case (kind)
        K_GOOD: begin
          cur_scn = "good"; probe_alive;
        end
        K_BADMAGIC: begin
          cur_scn = "bad_magic"; por(2'b01);
          build_image(MAGIC ^ (32'h1 << rnd(32)), IMG_WORDS[15:0], 1'b1, 32'h0);
          stream(blob_len, 200_000, 0);
          check(rej_seen == 1 && acc_seen == 0, "corrupt magic must be refused");
          rejects = rejects + 1;
        end
        K_BADCRC: begin
          cur_scn = "bad_crc"; por(2'b01);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b0, $random(seed));
          stream(blob_len, 200_000, 0);
          check(rej_seen == 1 && acc_seen == 0, "corrupt CRC must be refused");
          rejects = rejects + 1;
        end
        K_OVERSIZE: begin
          cur_scn = "oversize"; por(2'b01);
          build_image(MAGIC, BANK_WORDS[15:0] + 1 + rnd(1000), 1'b1, 32'h0);
          stream(blob_len, 200_000, 0);
          check(rej_seen == 1 && acc_seen == 0, "oversize header must be refused");
          check(boot_sel === 1'b0, "oversize must never run");
          rejects = rejects + 1;
        end
        K_TRUNC: begin
          cur_scn = "truncated"; por(2'b01);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          cut = 1 + rnd(blob_len - 1);
          stream(cut, 200_000, 0);
          check(acc_seen == 0, "a cut stream must never commit");
          probe_alive;    // and must never brick what follows
        end
        K_LIE: begin
          cur_scn = "storage_lie"; por(2'b01);
          lie_addr = rnd(IMG_WORDS);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          stream(blob_len, 200_000, 0);
          check(rej_seen == 1 && acc_seen == 0,
                "a lying word must fail the stored-image CRC");
          check(boot_sel === 1'b0, "a lying bank must never run");
          lie_addr = -1;
          rejects = rejects + 1;
        end
        K_GAPPY: begin
          cur_scn = "gappy_good"; por(2'b01);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          stream(blob_len, 400_000, 25);
          check(acc_seen == 1 && rej_seen == 0,
                "silences between bytes must not corrupt a good image");
          check(boot_sel === 1'b1, "the gappy image must still run");
          commits = commits + 1;
        end
        K_MIDPOR: begin
          cur_scn = "midload_por"; por(2'b01);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          cut = 1 + rnd(blob_len - 1);
          stream(cut, 200_000, 0);
          probe_alive;    // reset lands mid-load; the next boot must work
        end
        K_GOLDEN: begin
          cur_scn = "golden"; por(2'b00);
          repeat (150) @(posedge clk);
          check(boot_sel === 1'b0, "golden strap must fetch ROM");
        end
        K_BANKB: begin
          // the OTHER bank: strap 10 loads and runs bank B
          cur_scn = "bank_b"; por(2'b10);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          stream(blob_len, 200_000, 0);
          check(acc_seen == 1 && rej_seen == 0, "bank B image must commit");
          check(boot_sel === 1'b1, "bank B must run");
          check(bank === 1'b1, "and the fetch mux must point AT bank B");
          commits = commits + 1;
        end
        K_HOST: begin
          // host mode: a fresh image arrives while the die is running,
          // and must be staged into the INACTIVE bank without
          // disturbing the one under the CPU's feet
          cur_scn = "host_reload"; por(2'b11);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          stream(blob_len, 200_000, 0);
          check(acc_seen == 1, "host mode must accept the first image");
          check(boot_sel === 1'b1, "and run it");
          k = bank;
          acc_seen = 0; rej_seen = 0;
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          stream(blob_len, 200_000, 0);
          check(acc_seen == 1 && rej_seen == 0,
                "a second image must land while running");
          check(boot_sel === 1'b1, "the die must never stop running");
          check(bank !== k[0:0],
                "the reload must land in the INACTIVE bank");
          commits = commits + 2;
        end
        K_SIGFAIL: begin
          // a perfect image the signature refuses: the CRC gate is not
          // the only gate, and until now nothing ever proved it
          cur_scn = "sig_refused"; por(2'b01);
          build_image(MAGIC, IMG_WORDS[15:0], 1'b1, 32'h0);
          sig_ok = 1'b0;
          stream(blob_len, 200_000, 0);
          check(rej_seen == 1 && acc_seen == 0,
                "a refused signature must refuse the image");
          check(boot_sel === 1'b0, "and it must never run");
          sig_ok = 1'b1;
          rejects = rejects + 1;
        end
        K_SIGNON_RACE: begin
          // sign-on and watchdog failure on the SAME edge. The loader
          // used to let the sign-on erase the mark the watchdog had
          // just set, so the ladder swapped banks forever instead of
          // falling to the mask ROM. It must SETTLE.
          cur_scn = "signon_race"; probe_alive;
          for (k = 0; k < 6; k = k + 1) begin
            signon  = 1'b1;
            wd_fail = 1'b1;
            @(posedge clk);
            signon  = 1'b0;
            wd_fail = 1'b0;
            repeat (20) @(posedge clk);
          end
          repeat (200) @(posedge clk);
          check(boot_sel === 1'b0,
                "a die that keeps failing must REACH golden, not oscillate");
          reverts = reverts + 1;
        end
        K_WDFAIL: begin
          cur_scn = "wd_fail"; probe_alive;
          wd_fail = 1'b1;
          @(posedge clk);
          wd_fail = 1'b0;
          k = 0;
          while (k < 200 && boot_sel !== 1'b0) begin @(posedge clk); k = k + 1; end
          check(boot_sel === 1'b0, "watchdog-failed image must fall back");
          reverts = reverts + 1;
        end
      endcase
      episodes_run = episodes_run + 1;
    end
  endtask

  // ------------------------------------------------------------------ runner
  integer n_episodes, e, k;

  initial begin
    clk = 1'b0; checks_done = 0; episodes_run = 0;
    commits = 0; rejects = 0; reverts = 0;
    m_ack = 1'b0; m_rdt = 32'h0; lie_addr = -1; guards_on = 1'b0;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    seed0 = seed;
    if (!$value$plusargs("EPISODES=%d", n_episodes)) n_episodes = 120;
    for (k = 0; k < NKINDS; k = k + 1) kind_count[k] = 0;

    guards_on = 1'b1;
    for (e = 0; e < n_episodes; e = e + 1) begin
      if (e % 10 == 9) episode(K_GOOD);        // the liveness cadence
      else             episode(rnd(NKINDS));
    end

    // the storm must have been a storm: every kind drawn enough to count
    for (k = 0; k < NKINDS; k = k + 1) begin
      $display("  kind %0d drawn %0d times", k, kind_count[k]);
      if (kind_count[k] < 3) begin
        $display("FAIL coverage hole: kind %0d drawn only %0d times (seed %0d)",
                 k, kind_count[k], seed0);
        $fatal(1);
      end
    end
    $display("SV_FUZZ: PASS seed=%0d episodes=%0d commits=%0d rejects=%0d reverts=%0d checks=%0d",
             seed0, episodes_run, commits, rejects, reverts, checks_done);
    $finish;
  end

  initial begin
    #400_000_000;
    $display("FAIL [%0s] bench watchdog: the storm hung", cur_scn);
    $fatal(1);
  end

endmodule

`default_nettype wire
