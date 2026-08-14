// =============================================================================
// ZIRH-2 product program P1 - sliced SRAM word: 5 x RM_IHPSG13_1P_1024x8
// zirh_sram39.v
//
// The memory workstream's first real block: a 1024-word x 32-bit
// SECDED-protected memory built from five open-PDK SRAM macros, 8
// stored bits each (4 data slices + 1 parity slice holding the 6
// Hamming bits and the overall bit). The codeword is EXACTLY the flop
// RAM's - the same zirh_secded.vh include, guarded by the same formal
// proof - so beam data from the two memories is directly comparable:
// same code, different storage physics.
//
// Why sliced: a physical multi-bit upset is confined to one macro; at
// most one slice of any logical word is touched per event footprint
// that stays inside a macro, and the per-word SECDED absorbs one
// slice-resident bit. The slicing price and its escape behaviour are
// a placement-A/B-style experiment of their own (PROGRAM.md A2), and
// the c2 column mux inside the macro interleaves adjacent columns
// across two words, degrading small intra-row clusters to one bit per
// word before the slicing argument is even needed.
//
// Bus behaviour (the ROM ack lesson, applied from birth):
//   * the macro reads SYNCHRONOUSLY, so the ack is REGISTERED and
//     lands exactly on the cycle the decoded data is valid - a
//     combinational ack here would hand the CPU stale rubbish one
//     cycle early (measured twice on this project, never again)
//   * read:          issue / decode / registered ack with data
//   * full write:    encode combinational, registered ack
//   * partial write: issue read / decode+merge+write / registered ack
//   * scrub-on-read: a correctable read writes the fixed codeword
//     back in the cycle after the ack; a transaction arriving in that
//     cycle is simply held one cycle (the bus waits on ack anyway)
//
// Events mirror zirh_ecc_ram: evt pulses only when a stored word's
// decode is USED (reads, RMW merges) - full writes over garbage are
// not phantom corrections.
//
// BACKGROUND SCRUBBER (PROGRAM.md A3). Scrub-on-read is not enough:
// a word firmware never reads accumulates errors until two independent
// upsets meet in it and the loss is uncorrectable. A TMR'd background
// FSM walks the whole address space at a fixed rate through the same
// read-correct-writeback path, stealing only bus-idle cycles - a bus
// transaction is never delayed by more than the one in-flight scrub
// beat. Sizing: with per-word upset rate r and full-sweep period T_s,
// the probability a second upset lands in an already-hit word before
// the sweep returns is ~ r x T_s per word; for the datasheet,
// P(uncorrectable)/word/sweep ~ (r x T_s)^2 / 2. SCRUB_DIV_LOG2 sets
// one scrub beat every 2^N cycles: at 20 MHz and N=10 the 1024-word
// sweep completes in ~54 ms, five orders under any credible orbital
// upset interval.
//
// ADDRESS-IN-ECC (PROGRAM.md A4). SECDED protects data; a SET on the
// address path writes correct-looking data to the WRONG word - the
// silent memory counterpart of the ZOMBIE class. The write path XORs
// an address-derived mask over the parity positions and the overall
// bit; the read path XORs the same mask back. Matching addresses
// cancel exactly; ANY single-bit address difference between the row
// that was written and the row that is read yields a nonzero syndrome
// with a CLEAN overall bit - the uncorrectable signature, by
// construction (the mask carries even weight: 6 folded parity bits
// plus their own parity in the overall position). The protection
// boundary is the module port: corruption upstream of the port
// changes mask and row together and is bus-level work, stated
// honestly here.
//
// The BIST port set is tied off here; production test wiring is the
// DFT workstream (PROGRAM.md F28), not a bring-up concern.
// =============================================================================

`default_nettype none

module zirh_sram39 #(
    parameter integer SCRUB_DIV_LOG2 = 10   // one scrub beat / 2^N cycles
) (
    input  wire        clk,
    input  wire        rst_n,

    // scrub gate: hold low until boot initialization has written every
    // word (the sweep decodes rows; sweeping preinitialization garbage
    // is pointless, and in simulation it is X). Integration wires this
    // to a control register.
    input  wire        scrub_en_i,

    // bus slave: words 0..1023 at adr[11:2]
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire [3:0]  sel_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    output reg         evt_corr_o,
    output reg         evt_uncorr_o,
    output reg         evt_scrub_corr_o,  // background sweep repaired a word
    output wire        err_o,             // scrubber/bist TMR mismatch

    // BIST control (docs/DEBUG-DFT.md: production screening, commanded
    // flight self-test and the A6 beam pattern-scan share this engine).
    // BIST is exclusive and destructive: quiesce the bus, expect the
    // array reinitialized after. Bus accesses during BIST still ack
    // (nothing hangs) but data is undefined.
    input  wire        bist_start_i,
    input  wire [1:0]  bist_mode_i,   // 0 march c-, 1 cb fill, 2 read-scan
    output wire        bist_busy_o,
    output wire        bist_pass_o,
    output wire [15:0] bist_fail_cnt_o,
    output wire [9:0]  bist_fail_adr_o,
    output wire [4:0]  bist_fail_map_o

`ifdef FORMAL
    // same contract as zirh_ecc_ram: fault XOR on the read view only
    , input wire [38:0] f_corrupt_i
`endif
);

    `include "zirh_secded.vh"

    // --- transaction FSM ----------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_RD = 2'd1,
                 S_SCRUB_RD = 2'd2, S_SCRUB_FIX = 2'd3;

    reg [1:0] state;
    // the row a read was ISSUED to - decode and writeback must use the
    // captured row, not a bus address that may have moved on
    reg  [9:0] row_q;
    wire [9:0] widx = adr_i[11:2];

    wire full_wr = &sel_i;

    // ~ack_q frames the transaction: without it, a master holding cyc
    // through its ack cycle would relaunch the same access and the extra
    // ack would land on someone else's transaction at the bus mux
    wire issue_rd  = (state == S_IDLE) & cyc_i & ~ack_q
                   & (~we_i | (we_i & ~full_wr));
    wire decode_cy = (state == S_RD);

    // --- background scrubber ------------------------------------------------
    // divider ticks a pending flag; the FSM consumes it on a bus-idle
    // cycle. Counter and address walk in TMR registers: an upset in the
    // scrubber must not become a scribble engine.
    wire [SCRUB_DIV_LOG2-1:0] div_q;
    wire div_err;
    zirh_tmr_reg #(.WIDTH(SCRUB_DIV_LOG2)) u_sdiv (
        .clk(clk), .rst_n(rst_n), .en_i(1'b1),
        .d_i(div_q + {{(SCRUB_DIV_LOG2-1){1'b0}}, 1'b1}),
        .q_o(div_q), .err_o(div_err));
    wire scrub_tick = (div_q == {SCRUB_DIV_LOG2{1'b1}});

    // the scrub DECISION is taken at a clock edge and everything the
    // macros see afterwards derives from registered state - the first
    // build muxed the macro address combinationally between the bus
    // and the scrub counter, and a bus request landing inside a scrub
    // cycle steered the repair write to the wrong row (caught in
    // simulation as silent corruption of freshly written words)
    wire pend_q, pend_err;
    wire scrub_take = (state == S_IDLE) & ~cyc_i & pend_q & scrub_en_i;
    zirh_tmr_reg #(.WIDTH(1)) u_pend (
        .clk(clk), .rst_n(rst_n), .en_i(scrub_tick | scrub_take),
        .d_i(scrub_tick), .q_o(pend_q), .err_o(pend_err));

    wire [9:0] sadr_q;
    wire sadr_err;
    zirh_tmr_reg #(.WIDTH(10)) u_sadr (
        .clk(clk), .rst_n(rst_n), .en_i(scrub_take),
        .d_i(sadr_q + 10'd1), .q_o(sadr_q), .err_o(sadr_err));

    // --- BIST engine --------------------------------------------------------
    wire bist_en, bist_men, bist_wen, bist_ren;
    wire [9:0] bist_adr;
    wire [7:0] bist_din;
    wire bist_err;

    zirh_sram_bist u_bist (
        .clk(clk), .rst_n(rst_n),
        .start_i(bist_start_i), .mode_i(bist_mode_i),
        .q0_i(q0), .q1_i(q1), .q2_i(q2), .q3_i(q3), .q4_i(qflat[39:32]),
        .bist_en_o(bist_en), .bist_men_o(bist_men),
        .bist_wen_o(bist_wen), .bist_ren_o(bist_ren),
        .bist_adr_o(bist_adr), .bist_din_o(bist_din),
        .busy_o(bist_busy_o), .pass_o(bist_pass_o),
        .fail_cnt_o(bist_fail_cnt_o), .fail_adr_o(bist_fail_adr_o),
        .fail_map_o(bist_fail_map_o), .err_o(bist_err));

    assign err_o = div_err | pend_err | sadr_err | bist_err;

    // --- the five slices ----------------------------------------------------
    // read data returns one cycle after ren; write is same-cycle
    wire [38:0] enc_wr;
    wire        wr_now;      // write strobe for all five macros

    // MEN held high: the enable is a power feature, not a correctness
    // one, and gating it bought the first build nothing but hazards
    wire men = 1'b1;
    wire ren = issue_rd | (state == S_SCRUB_RD);
    wire [9:0] row = (state != S_IDLE) ? row_q : widx;

    // the Cycle-12 lesson made structural: ONE generate loop, identical
    // wiring by construction - a mechanical edit can no longer reach
    // four slices and silently miss the fifth
    wire [39:0] dflat = {1'b0, enc_wr[38:32], enc_wr[31:0]};
    wire [39:0] qflat;

    genvar g;
    generate
        for (g = 0; g < 5; g = g + 1) begin : g_slice
            zirh_sram39_slice u_m (
                .clk(clk), .men(men), .wen(wr_now), .ren(ren),
                .adr(row), .d(dflat[8*g +: 8]), .q(qflat[8*g +: 8]),
                .bist_en(bist_en), .bist_men(bist_men),
                .bist_wen(bist_wen), .bist_ren(bist_ren),
                .bist_adr(bist_adr), .bist_din(bist_din));
        end
    endgenerate

    wire [7:0] q0 = qflat[7:0];
    wire [7:0] q1 = qflat[15:8];
    wire [7:0] q2 = qflat[23:16];
    wire [7:0] q3 = qflat[31:24];
    wire [7:0] q4 = qflat[39:32];

    // --- decode (valid in the cycle after issue_rd) -------------------------
    // address mask: 6 folded bits over the parity positions plus their
    // parity in the overall bit - even weight, so an address mismatch
    // always decodes as UNCORRECTABLE, never as a clean or correctable
    // word (see header)
    function [38:0] amask;
        input [9:0] a;
        reg [5:0] p6;
        integer i;
        begin
            p6 = a[5:0] ^ {2'b00, a[9:6]};
            amask = 39'd0;
            for (i = 0; i < 6; i = i + 1)
                amask[(1 << i) - 1] = p6[i];
            amask[38] = ^p6;
        end
    endfunction

`ifdef FORMAL
    wire [38:0] raw = ({q4[6:0], q3, q2, q1, q0} ^ amask(row_q))
                      ^ f_corrupt_i;
`else
    wire [38:0] raw = {q4[6:0], q3, q2, q1, q0} ^ amask(row_q);
`endif
    wire [38:1] cw_raw  = raw[37:0];
    wire [5:0]  syn     = syndrome_of(cw_raw);
    wire        ovr_bad = (^cw_raw) ^ raw[38];

    wire correct_cw  = (syn != 6'd0) &  ovr_bad & (syn <= 6'd38);
    wire correct_ovr = (syn == 6'd0) &  ovr_bad;
    wire uncorr      = ((syn != 6'd0) & ~ovr_bad) |
                       ( ovr_bad & (syn > 6'd38));
    wire had_corr    = correct_cw | correct_ovr;

    wire [38:1] cw_fixed = correct_cw ? (cw_raw ^ (38'b1 << (syn - 1)))
                                      : cw_raw;
    wire [38:0] fixed    = {^cw_fixed, cw_fixed};

    wire [37:0] gathered = gather_data_ext(cw_fixed);
    wire [31:0] rd_data  = gathered[31:0];

    // --- merge + write ------------------------------------------------------
    wire [31:0] merged = {sel_i[3] ? dat_i[31:24] : rd_data[31:24],
                          sel_i[2] ? dat_i[23:16] : rd_data[23:16],
                          sel_i[1] ? dat_i[15:8]  : rd_data[15:8],
                          sel_i[0] ? dat_i[7:0]   : rd_data[7:0]};

    // what gets written when wr_now strobes:
    //   IDLE + full write  : encode(dat_i)
    //   S_RD  + we (RMW)   : encode(merged)      (registered into S_WB? no -
    //                        the merge is combinational off the decode, so
    //                        the write happens directly in the decode cycle)
    //   S_RD  + rd + corr  : fixed               (scrub-on-read write-back)
    wire wr_full  = (state == S_IDLE) & cyc_i & ~ack_q & we_i & full_wr;
    wire wr_rmw   = decode_cy & we_i;
    wire wr_scrub = decode_cy & ~we_i & had_corr;

    wire sweep_fix = (state == S_SCRUB_FIX) & had_corr;

    assign wr_now = wr_full | wr_rmw | wr_scrub | sweep_fix;
    assign enc_wr = (wr_full ? encode(dat_i)
                  :  wr_rmw  ? encode(merged)
                  :            fixed)
                  ^ amask(wr_full ? widx : row_q);

    // --- FSM + registered outputs ------------------------------------------
    reg [31:0] rdt_q;
    reg        ack_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            row_q            <= 10'd0;
            ack_q            <= 1'b0;
            evt_corr_o       <= 1'b0;
            evt_uncorr_o     <= 1'b0;
            evt_scrub_corr_o <= 1'b0;
        end else begin
            ack_q            <= 1'b0;
            evt_corr_o       <= 1'b0;
            evt_uncorr_o     <= 1'b0;
            evt_scrub_corr_o <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (wr_full)       ack_q <= 1'b1;
                    else if (issue_rd) begin
                        row_q <= widx;
                        state <= S_RD;
                    end else if (scrub_take) begin
                        row_q <= sadr_q;
                        state <= S_SCRUB_RD;
                    end
                end
                S_RD: begin
                    // decode cycle: data + ack for reads and RMWs; the
                    // scrub or RMW write strobes the port this same
                    // cycle, so IDLE is safe to reenter immediately
                    rdt_q        <= rd_data;
                    ack_q        <= 1'b1;
                    evt_corr_o   <= had_corr;
                    evt_uncorr_o <= uncorr;
                    state        <= S_IDLE;
                end
                S_SCRUB_RD: state <= S_SCRUB_FIX;   // read in flight
                S_SCRUB_FIX: begin
                    // repair (if any) strobes this cycle at row_q;
                    // no ack, the bus never sees the beat
                    evt_scrub_corr_o <= had_corr;
                    evt_uncorr_o     <= uncorr;
                    state            <= S_IDLE;
                end
                default: state <= S_IDLE;   // safe-state trap
            endcase
        end
    end

    `include "zirh_assert.vh"
    // the FSM has no legal fourth state; an ack cycle always finds the
    // FSM back in IDLE (both ack paths return there as they fire)
    `ZIRH_ASSERT(a_state_legal, state <= S_SCRUB_FIX)
    `ZIRH_ASSERT(a_ack_from_idle, !ack_q || (state == S_IDLE))

    assign rdt_o = rdt_q;
    assign ack_o = ack_q;

endmodule

// --- one slice: the PDK macro, BIST port wired to the march engine -----------
module zirh_sram39_slice (
    input  wire       clk,
    input  wire       men,
    input  wire       wen,
    input  wire       ren,
    input  wire [9:0] adr,
    input  wire [7:0] d,
    output wire [7:0] q,
    input  wire       bist_en,
    input  wire       bist_men,
    input  wire       bist_wen,
    input  wire       bist_ren,
    input  wire [9:0] bist_adr,
    input  wire [7:0] bist_din
);

    RM_IHPSG13_1P_1024x8_c2_bm_bist u_macro (
        .A_CLK       (clk),
        .A_MEN       (men),
        .A_WEN       (wen),
        .A_REN       (ren),
        .A_ADDR      (adr),
        .A_DIN       (d),
        .A_DLY       (1'b0),
        .A_DOUT      (q),
        .A_BM        (8'hFF),
        .A_BIST_CLK  (clk),
        .A_BIST_EN   (bist_en),
        .A_BIST_MEN  (bist_men),
        .A_BIST_WEN  (bist_wen),
        .A_BIST_REN  (bist_ren),
        .A_BIST_ADDR (bist_adr),
        .A_BIST_DIN  (bist_din),
        .A_BIST_BM   (8'hFF)
    );

endmodule

`default_nettype wire
