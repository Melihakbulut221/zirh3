// =============================================================================
// ZIRH product program P2 - boot controller: the ROM becomes a loader
// zirh_boot_ctrl.v
//
// docs/BOOT.md is the contract; this is the hardware half. Transport-
// agnostic: consumes a byte stream (valid/ready), masters the SECDED
// SRAM bus port for load and read-back, and owns the two signals the
// SoC honors at fetch: boot_sel_o (ROM vs SRAM) and bank_o.
//
// The properties the suite proves:
//   * a bank's valid flag flips ONLY after the STORED image's CRC
//     matches the header (read-back through the SECDED-corrected
//     port, not the stream) - an interrupted or corrupted load can
//     never produce a bootable-looking bank
//   * rejects fall back: other valid bank first, golden ROM last
//   * a watchdog failure without firmware signon reverts to the other
//     valid bank automatically, then to golden - no ground contact
//   * in HOST mode the controller accepts a fresh image while running
//     (the ISP path), always into the INACTIVE bank
//
// This block lives in the POR domain (like housekeeping): a watchdog
// reset of the SoC must not erase bank bookkeeping, or the revert
// logic would forget why it rebooted. All state is TMR with the
// safe-state default landing on GOLDEN - a mangled loader must fail
// toward the mask ROM, never toward silence.
// =============================================================================

`default_nettype none

module zirh_boot_ctrl #(
    parameter integer BANK_WORDS = 512,   // words per bank, 2 banks
    parameter PROTECT = 1                 // 0: plain regs (safe-fail host)
) (
    input  wire        clk,
    input  wire        rst_n,          // POR only - NOT the watchdog reset

    input  wire [1:0]  strap_i,        // 00 golden 01 bankA 10 bankB 11 host

    // image byte stream (from NVM reader / UART bridge / CAN reassembler)
    input  wire        st_valid_i,
    input  wire [7:0]  st_data_i,
    output wire        st_ready_o,

    // product-chip hook: signature verdict for the staged image; the
    // experiment class ties it high (CRC-only)
    input  wire        sig_ok_i,

    // firmware signon (BOOT_OK register strobe) and watchdog verdict
    input  wire        signon_i,
    input  wire        wd_fail_i,

    // SRAM bus master (full-word writes, reads for verification)
    output wire        m_cyc_o,
    output wire [31:0] m_adr_o,
    output wire [31:0] m_dat_o,
    output wire        m_we_o,
    input  wire [31:0] m_rdt_i,
    input  wire        m_ack_i,

    // to the SoC fetch mux and telemetry
    output wire        boot_sel_o,     // 0 fetch ROM (golden), 1 fetch SRAM
    output wire        bank_o,         // active bank when boot_sel=1
    output reg         evt_accept_o,   // 1-cycle: image committed
    output reg         evt_reject_o,   // 1-cycle: image refused
    output wire        err_o           // any loader TMR mismatch
);

    localparam MAGIC = 32'h5A495248;
    localparam integer IDXW = $clog2(BANK_WORDS);

    // --- CRC32 (IEEE 802.3 reflected, init/xorout all-ones) -----------------
    function [31:0] crc32_byte;
        input [31:0] c;
        input [7:0]  b;
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'h0, b};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc32_byte = x;
        end
    endfunction

    // --- states -------------------------------------------------------------
    localparam [2:0] S_STRAP  = 3'd0,   // sample straps after reset
                     S_GOLDEN = 3'd1,   // run mask ROM, load nothing
                     S_HDR    = 3'd2,   // collect the 12-byte header
                     S_LOAD   = 3'd3,   // stream payload into the bank
                     S_VERIFY = 3'd4,   // read back, CRC the stored image
                     S_RUN    = 3'd5;   // committed; watch signon/watchdog

    wire [2:0] state_q;
    reg  [2:0] state_d;
    wire       state_err;
    zirh_boot_reg #(.WIDTH(3), .PROTECT(PROTECT)) u_state (
        .clk(clk), .rst_n(rst_n), .en_i(1'b1), .d_i(state_d),
        .q_o(state_q), .err_o(state_err));

    // bank bookkeeping: preference, per-bank valid, per-bank suspect
    wire pref_q, va_q, vb_q, sa_q, sb_q, sel_q;
    reg  pref_d, va_d, vb_d, sa_d, sb_d, sel_d;
    wire e1, e2, e3, e4, e5, e6;
    zirh_boot_reg #(.WIDTH(1), .PROTECT(PROTECT)) u_pref (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(pref_d), .q_o(pref_q), .err_o(e1));
    zirh_boot_reg #(.WIDTH(1), .PROTECT(PROTECT)) u_va (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(va_d), .q_o(va_q), .err_o(e2));
    zirh_boot_reg #(.WIDTH(1), .PROTECT(PROTECT)) u_vb (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(vb_d), .q_o(vb_q), .err_o(e3));
    zirh_boot_reg #(.WIDTH(1), .PROTECT(PROTECT)) u_sa (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sa_d), .q_o(sa_q), .err_o(e4));
    zirh_boot_reg #(.WIDTH(1), .PROTECT(PROTECT)) u_sb (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sb_d), .q_o(sb_q), .err_o(e5));
    zirh_boot_reg #(.WIDTH(1), .PROTECT(PROTECT)) u_sel (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(sel_d), .q_o(sel_q), .err_o(e6));

    // load-path working set
    wire [1:0]  strap_q;
    wire        tgt_q;          // bank being loaded
    wire [15:0] hlen_q;
    // Cycle 47: the version is STORED now, and a monotonic floor
    // lives beside it. Both in the POR domain like the rest of the
    // bookkeeping - a watchdog reset must not erase the rollback
    // floor, or one starved boot would reopen the door the floor
    // exists to close. The floor does reset at power-on: that is the
    // experiment-class subset, recorded in docs/BOOT.md, and the
    // product part seeds it from the MRAM config page instead.
    wire [15:0] ver_q, vmin_q;
    reg  [15:0] ver_d, vmin_d;
    wire        e_ver, e_vmin;
    wire [31:0] hcrc_q, crc_q, word_q;
    wire [IDXW-1:0] idx_q;
    wire [3:0]  bcnt_q;
    reg  [1:0]  strap_d;
    reg         tgt_d;
    reg  [15:0] hlen_d;
    reg  [31:0] hcrc_d, crc_d, word_d;
    reg  [IDXW-1:0] idx_d;
    reg  [3:0]  bcnt_d;
    wire e7, e8, e9, e11, e12, e13, e14;
    zirh_boot_reg #(.WIDTH(2), .PROTECT(PROTECT))  u_strap (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(strap_d), .q_o(strap_q), .err_o(e7));
    zirh_boot_reg #(.WIDTH(1), .PROTECT(PROTECT))  u_tgt  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(tgt_d), .q_o(tgt_q), .err_o(e8));
    zirh_boot_reg #(.WIDTH(16), .PROTECT(PROTECT)) u_hlen (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(hlen_d), .q_o(hlen_q), .err_o(e9));
    zirh_boot_reg #(.WIDTH(16), .PROTECT(PROTECT)) u_ver  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(ver_d), .q_o(ver_q), .err_o(e_ver));
    zirh_boot_reg #(.WIDTH(16), .PROTECT(PROTECT)) u_vmin (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(vmin_d), .q_o(vmin_q), .err_o(e_vmin));
    zirh_boot_reg #(.WIDTH(32), .PROTECT(PROTECT)) u_hcrc (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(hcrc_d), .q_o(hcrc_q), .err_o(e11));
    zirh_boot_reg #(.WIDTH(32), .PROTECT(PROTECT)) u_crc  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(crc_d), .q_o(crc_q), .err_o(e12));
    zirh_boot_reg #(.WIDTH(32), .PROTECT(PROTECT)) u_word (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(word_d), .q_o(word_q), .err_o(e13));
    zirh_boot_reg #(.WIDTH(IDXW), .PROTECT(PROTECT)) u_idx  (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(idx_d), .q_o(idx_q), .err_o(e14));
    // byte counter is small and self-healing through the flow; TMR too
    wire e15;
    zirh_boot_reg #(.WIDTH(4), .PROTECT(PROTECT))  u_bcnt (.clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(bcnt_d), .q_o(bcnt_q), .err_o(e15));

    assign err_o = state_err | e1 | e2 | e3 | e4 | e5 | e6 | e7 | e8
                 | e9 | e11 | e12 | e13 | e14 | e15 | e_ver | e_vmin;

    // --- bus mastering ------------------------------------------------------
    // sub-phase: in LOAD, a completed word issues one write; in VERIFY,
    // each word issues one read. cyc holds until ack (the SRAM answers
    // in a fixed small number of cycles; its ~ack framing pairs with
    // this master's cyc-drop-after-ack).
    wire wr_go = (state_q == S_LOAD)   & (bcnt_q == 4'd4);
    wire rd_go = (state_q == S_VERIFY) & (bcnt_q == 4'd0);

    assign m_cyc_o = wr_go | rd_go;
    assign m_we_o  = wr_go;
    assign m_dat_o = word_q;
    // word address = bank base + index, at whatever width BANK_WORDS
    // needs - the 10-bit builder this replaced was sized for the
    // ZIRH-2 die's 512-word banks and silently truncated any larger
    // bank's base to zero (Cycle 17: the program store grows)
    wire [27:0] word_adr = (tgt_q ? BANK_WORDS[27:0] : 28'd0)
                           + {{(28-IDXW){1'b0}}, idx_q};
    assign m_adr_o = {2'b00, word_adr, 2'b00};

    // stream accepted only while collecting header or payload bytes
    assign st_ready_o = ((state_q == S_HDR) & (bcnt_q < 4'd12))
                      | ((state_q == S_LOAD) & (bcnt_q < 4'd4));
    wire take = st_valid_i & st_ready_o;

    // --- outputs ------------------------------------------------------------
    assign boot_sel_o = sel_q;
    assign bank_o     = pref_q;

    // fallback resolution: prefer the OTHER bank if it is valid and not
    // suspect; otherwise golden
    wire other_ok = tgt_q ? (va_q & ~sa_q) : (vb_q & ~sb_q);
    wire run_other_ok = pref_q ? (va_q & ~sa_q) : (vb_q & ~sb_q);

    // --- next-state ---------------------------------------------------------
    always @* begin
        state_d = state_q;
        pref_d  = pref_q;  va_d = va_q;  vb_d = vb_q;
        sa_d    = sa_q;    sb_d = sb_q;  sel_d = sel_q;
        strap_d = strap_q; tgt_d = tgt_q;
        hlen_d  = hlen_q;  hcrc_d = hcrc_q;
        ver_d   = ver_q;   vmin_d = vmin_q;
        crc_d   = crc_q;   word_d = word_q;
        idx_d   = idx_q;   bcnt_d = bcnt_q;
        evt_accept_o = 1'b0;
        evt_reject_o = 1'b0;

        case (state_q)
            S_STRAP: begin
                strap_d = strap_i;
                sel_d   = 1'b0;
                bcnt_d  = 4'd0;
                idx_d   = {IDXW{1'b0}};
                crc_d   = 32'hFFFFFFFF;
                case (strap_i)
                    2'b00: state_d = S_GOLDEN;
                    2'b01: begin tgt_d = 1'b0; state_d = S_HDR; end
                    2'b10: begin tgt_d = 1'b1; state_d = S_HDR; end
                    2'b11: begin tgt_d = ~pref_q; state_d = S_HDR; end
                endcase
            end

            S_GOLDEN: sel_d = 1'b0;    // terminal until POR

            S_HDR: begin
                if (take) begin
                    // little-endian field assembly, byte 0..11
                    case (bcnt_q)
                        4'd0:  word_d[7:0]   = st_data_i;
                        4'd1:  word_d[15:8]  = st_data_i;
                        4'd2:  word_d[23:16] = st_data_i;
                        4'd3:  word_d[31:24] = st_data_i;
                        4'd4:  hlen_d[7:0]   = st_data_i;
                        4'd5:  hlen_d[15:8]  = st_data_i;
                        4'd6:  ver_d[7:0]  = st_data_i;
                        4'd7:  ver_d[15:8] = st_data_i;
                        4'd8:  hcrc_d[7:0]   = st_data_i;
                        4'd9:  hcrc_d[15:8]  = st_data_i;
                        4'd10: hcrc_d[23:16] = st_data_i;
                        default: hcrc_d[31:24] = st_data_i;
                    endcase
                    bcnt_d = bcnt_q + 4'd1;
                end
                if (bcnt_q == 4'd12) begin
                    bcnt_d = 4'd0;
                    // the ROLLBACK gate sits with the other header
                    // checks: an image whose version is below the
                    // floor is refused before a single payload byte
                    // is taken, exactly like a bad magic. Equal is
                    // allowed - re-flashing the version you already
                    // run is legitimate maintenance, and the floor
                    // only ever moves UP, on accept.
                    if ((word_q == MAGIC) && (hlen_q != 16'd0)
                        && (hlen_q <= BANK_WORDS[15:0] - 16'd3)
                        && (ver_q >= vmin_q))
                        state_d = S_LOAD;
                    else begin
                        evt_reject_o = 1'b1;
                        state_d = other_ok ? S_RUN : S_GOLDEN;
                        if (other_ok) begin
                            pref_d = ~tgt_q;
                            sel_d  = 1'b1;
                        end
                    end
                end
            end

            S_LOAD: begin
                if (take) begin
                    case (bcnt_q)
                        4'd0: word_d[7:0]   = st_data_i;
                        4'd1: word_d[15:8]  = st_data_i;
                        4'd2: word_d[23:16] = st_data_i;
                        default: word_d[31:24] = st_data_i;
                    endcase
                    bcnt_d = bcnt_q + 4'd1;
                end
                if (wr_go & m_ack_i) begin
                    bcnt_d = 4'd0;
                    idx_d  = idx_q + 1'b1;
                    if (idx_q == hlen_q[IDXW-1:0] - 1'b1) begin
                        idx_d   = {IDXW{1'b0}};
                        state_d = S_VERIFY;
                    end
                end
            end

            S_VERIFY: begin
                // bcnt 0: read issued; on ack fold the stored word into
                // the CRC (read-back through the corrected port)
                if (rd_go & m_ack_i) begin
                    crc_d = crc32_byte(crc32_byte(crc32_byte(crc32_byte(
                                crc_q, m_rdt_i[7:0]), m_rdt_i[15:8]),
                                m_rdt_i[23:16]), m_rdt_i[31:24]);
                    idx_d = idx_q + 1'b1;
                    if (idx_q == hlen_q[IDXW-1:0] - 1'b1)
                        bcnt_d = 4'd1;          // all words folded
                end
                if (bcnt_q == 4'd1) begin
                    bcnt_d = 4'd0;
                    idx_d  = {IDXW{1'b0}};
                    if (((crc_q ^ 32'hFFFFFFFF) == hcrc_q) & sig_ok_i) begin
                        evt_accept_o = 1'b1;
                        vmin_d = ver_q;    // the floor rises with the ruling
                        if (tgt_q) begin vb_d = 1'b1; sb_d = 1'b0; end
                        else       begin va_d = 1'b1; sa_d = 1'b0; end
                        pref_d  = tgt_q;
                        sel_d   = 1'b1;
                        state_d = S_RUN;
                    end else begin
                        evt_reject_o = 1'b1;
                        state_d = other_ok ? S_RUN : S_GOLDEN;
                        if (other_ok) begin
                            pref_d = ~tgt_q;
                            sel_d  = 1'b1;
                        end
                    end
                end
            end

            S_RUN: begin
                if (wd_fail_i) begin
                    // the running bank failed to sign on: mark suspect,
                    // fall to the other valid bank, then golden
                    if (pref_q) sb_d = 1'b1;
                    else        sa_d = 1'b1;
                    if (run_other_ok) begin
                        pref_d = ~pref_q;
                        sel_d  = 1'b1;
                    end else begin
                        sel_d   = 1'b0;
                        state_d = S_GOLDEN;
                    end
                end else if ((strap_q == 2'b11) & st_valid_i) begin
                    // ISP: a fresh image arrives while running - stage it
                    // into the inactive bank (the running one is live).
                    // The waking byte is NOT consumed here: this state
                    // raises no ready, so a transport that honours the
                    // handshake re-offers it once HDR does. The block
                    // suite's loader model proves that path; the storm's
                    // simplified sender did not, which is what Cycle 44
                    // actually found.
                    tgt_d   = ~pref_q;
                    bcnt_d  = 4'd0;
                    idx_d   = {IDXW{1'b0}};
                    crc_d   = 32'hFFFFFFFF;
                    state_d = S_HDR;
                end
                // signon_i clears the suspect mark of the running bank -
                // the firmware proved itself. NEVER in the same cycle
                // the watchdog condemned that bank: a failure and a
                // sign-on together must resolve as FAILURE, or the
                // revert ladder erases its own evidence and ping-pongs
                // between two banks forever instead of reaching golden
                if (signon_i && !wd_fail_i) begin
                    if (pref_q) sb_d = 1'b0;
                    else        sa_d = 1'b0;
                end
            end

            default: begin
                // safe-state trap: a mangled loader fails toward the
                // immutable ROM, never toward silence
                sel_d   = 1'b0;
                state_d = S_GOLDEN;
            end
        endcase
    end

    // CRC accumulation over the INCOMING payload happens implicitly at
    // verification read-back only: the stored image is the truth, the
    // stream is just transport (docs/BOOT.md fault model).

    `include "zirh_assert.vh"
    // states beyond S_RUN do not exist; a committed bank implies its
    // valid flag; golden never fetches from SRAM
    `ZIRH_ASSERT(a_state_legal, state_q <= S_RUN)
    `ZIRH_ASSERT(a_sel_implies_valid,
                 !sel_q || (pref_q ? vb_q : va_q))
    // the array is touched ONLY while streaming payload: no other
    // state can write a bank, so GOLDEN can never scribble on one and
    // a ruling cannot be undone by a late write
    `ZIRH_ASSERT(a_write_implies_load, !m_we_o || (state_q == S_LOAD))

`ifdef FORMAL
    // ------------------------------------------------------------------
    // Cycle 39 - the trust anchor's theorems.
    //
    // Everything below is PROOF SCAFFOLDING: without -DFORMAL it does
    // not exist, so simulation and the ASIC netlist carry none of it.
    // The shadows live here rather than in the harness because these
    // are TRANSITION properties and this is where the state lives -
    // formal/f_boot.sv supplies the free inputs and the anti-vacuity
    // covers, exactly the split zirh_assert.vh describes.
    // ------------------------------------------------------------------
    // the shadows mirror the machine's OWN reset - a shadow that
    // survives reset reports yesterday's die and fails tomorrow's
    // theorem for reasons that have nothing to do with the design
    reg [2:0] f_state_p;
    reg       f_va_p, f_vb_p, f_ruled;
    reg [15:0] f_vmin_p;
    always @(posedge clk) begin
        if (!rst_n) begin
            f_state_p <= S_STRAP;
            f_va_p    <= 1'b0;
            f_vb_p    <= 1'b0;
            f_ruled   <= 1'b0;
            f_vmin_p  <= 16'd0;
        end else begin
            f_state_p <= state_q;
            f_va_p    <= va_q;
            f_vb_p    <= vb_q;
            f_vmin_p  <= vmin_q;
            if (evt_accept_o | evt_reject_o) f_ruled <= 1'b1;
        end
    end

    always @(posedge clk) if (rst_n) begin
        // THEOREM 1 - a bank becomes bootable only out of VERIFY. The
        // stream is transport; the only thing that can raise a valid
        // flag is the STORED image judged by its read-back CRC. An
        // interrupted, truncated or corrupted load cannot leave a
        // bank looking bootable, whatever the stream does.
        a_valid_rises_only_from_verify:
            assert (!((va_q & ~f_va_p) | (vb_q & ~f_vb_p))
                    || (f_state_p == S_VERIFY));

        // THEOREM 2 - GOLDEN is absorbing. One clock inside the mask
        // ROM state and the machine is there for good with the fetch
        // mux pointed at ROM: no stream, no strap wiggle, no watchdog
        // verdict can talk the die back into fetching SRAM.
        if (f_state_p == S_GOLDEN)
            a_golden_absorbing: assert ((state_q == S_GOLDEN) && !sel_q);

        // THEOREM 3 - a watchdog failure never erases its own
        // evidence. In any cycle the watchdog condemns the running
        // bank, no suspect mark may fall - otherwise a firmware
        // sign-on arriving on the same edge lets the revert ladder
        // swap banks forever and never reach the mask ROM, which is
        // exactly the shape a starving flight die would take.
        // (stated on the next-state values so it reads as what it
        // means: in THIS run cycle, with the watchdog condemning,
        // nothing is being cleared. A verified accept legitimately
        // clears a suspect mark, which is why the claim is scoped to
        // the running state rather than to wd_fail_i alone.)
        if ((state_q == S_RUN) && wd_fail_i)
            a_failure_never_clears_suspect:
                assert (!((sa_q & ~sa_d) | (sb_q & ~sb_d)));

        // THEOREM 4 - THE FLOOR NEVER FALLS. Whatever the stream,
        // the straps, the watchdog or the bus answers do, the
        // rollback floor is monotonic within a power-on session -
        // there is no path that lowers it, because a floor that can
        // be talked down is a suggestion.
        a_floor_never_falls: assert (vmin_q >= f_vmin_p);

        // the strengthening invariant that makes Theorem 5
        // inductive: an image IN FLIGHT already cleared the floor.
        // The header gate establishes it on entry to LOAD, nothing
        // writes the version outside header collection, and the
        // floor only moves at the accept edge itself - so the
        // property is preserved step to step, which is exactly what
        // induction needs and the bare commit-check could not give.
        if (state_q == S_LOAD || state_q == S_VERIFY)
            a_inflight_above_floor: assert (ver_q >= vmin_q);

        // THEOREM 5 - NOTHING BELOW THE FLOOR EVER COMMITS. At the
        // accept edge the stored image's version clears the floor
        // that stood before the ruling; the floor then rises to it.
        if (evt_accept_o)
            a_no_rollback_commit: assert (ver_q >= f_vmin_p);

        // reachability, checked by the cover stage: the floor
        // genuinely rises, and a version refusal genuinely happens -
        // a gate no image ever hits is a comment, not a gate
        c_floor_rises:     cover (vmin_q != 16'd0);
        c_version_refusal: cover (evt_reject_o && (ver_q < vmin_q));

        // THEOREM 6 - ONE RULING PER RESET at flight straps. Once the
        // loader has ruled it is done: it holds no bus, hears no
        // stream, and can never re-enter the load path. Host mode
        // (2'b11) is exempt BY DESIGN - that strap exists precisely to
        // accept a fresh image while the die keeps running.
        if (f_ruled && (strap_q != 2'b11)) begin
            a_ruling_is_final:  assert ((state_q == S_RUN)
                                        || (state_q == S_GOLDEN));
            a_ruled_is_deaf:    assert (!st_ready_o);
            a_ruled_writes_not: assert (!m_we_o);
        end
    end
`endif

endmodule

`default_nettype wire


// ----------------------------------------------------------------------------
// zirh_boot_reg - the loader's register primitive with a PROTECT knob.
// PROTECT=1 is the real thing (zirh_tmr_reg, voted feedback, mismatch
// pulse). PROTECT=0 is one plain register with err_o tied low - for a
// die whose area cannot carry the replicas and whose loader already
// fails SAFE: every confusion mode of this FSM lands on the mask ROM,
// and the image itself is judged by the read-back CRC either way. The
// generate scope lives HERE, inside the loader, so no hierarchical
// path anywhere else in the design moves.
// ----------------------------------------------------------------------------
module zirh_boot_reg #(
    parameter WIDTH  = 8,
    parameter [WIDTH-1:0] RESET_VALUE = {WIDTH{1'b0}},
    parameter PROTECT = 1
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             en_i,
    input  wire [WIDTH-1:0] d_i,
    output wire [WIDTH-1:0] q_o,
    output wire             err_o
);

    generate
    if (PROTECT != 0) begin : g_tmr
        zirh_tmr_reg #(.WIDTH(WIDTH), .RESET_VALUE(RESET_VALUE)) u_r (
            .clk(clk), .rst_n(rst_n), .en_i(en_i), .d_i(d_i),
            .q_o(q_o), .err_o(err_o));
    end else begin : g_plain
        reg [WIDTH-1:0] q_q;
        always @(posedge clk) begin
            if (!rst_n)    q_q <= RESET_VALUE;
            else if (en_i) q_q <= d_i;
        end
        assign q_o   = q_q;
        assign err_o = 1'b0;
    end
    endgenerate

endmodule
