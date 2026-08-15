// =============================================================================
// ZIRH-3 - the 64 KB paged bank (Cycle 14 rung 5: the storage leg)
// src/zirh_bank64.v
//
// Sixteen copies of the PROVEN sliced-SECDED bank - the block whose
// ECC, scrubber, address fold and BIST have carried the program since
// its own bring-up - composed into 64 KB without one line of its RTL
// changing. Eighty 1024x8 macros, every word 32+6+1 across five
// slices, every page scrubbed in the background.
//
// Two masters, two views, on purpose:
//   * The CPU sees the slot-4 window (4 KB) through the PAGE register
//     (the slot-5 doorway's 0x0C word). Paging costs the software one
//     store to switch context; it costs the bus map nothing - the ROM
//     firmware and every proven base address stand untouched.
//   * The debugger's SBA sees the FLAT 64 KB: its address bus is full
//     width, so bits [15:12] select the page directly. A bench tool
//     never pages; a flight CPU never sees more than its window.
//
// The BIST doorway follows the page register too: one march engine
// per page, started page by page - the fail record stays per-macro
// like the beam instrument's.
// =============================================================================

`default_nettype none

module zirh_bank64 #(
    parameter integer SCRUB_DIV_LOG2 = 10,
    // 16 pages = 64 KB is the die. Simulation suites may build fewer
    // pages for wall-clock (the paging mechanism is page-count
    // agnostic); synthesis and the guard always measure the full 16.
    parameter integer PAGES = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scrub_en_i,

    // CPU/window port: 4 KB window, page_i selects which page
    input  wire [3:0]  page_i,
    input  wire        cyc_i,
    input  wire [31:0] adr_i,        // window-relative (low 12 bits used)
    input  wire [31:0] dat_i,
    input  wire [3:0]  sel_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // SBA/flat port request rides the same bus signals when sba_flat_i
    // is high: adr_i[15:12] overrides the page for THAT access
    input  wire        sba_flat_i,

    // MBIST doorway, steered to the selected page
    input  wire        bist_start_i,
    input  wire [1:0]  bist_mode_i,
    output wire        bist_busy_o,
    output wire        bist_pass_o,
    output wire [15:0] bist_fail_cnt_o,
    output wire [9:0]  bist_fail_adr_o,
    output wire [4:0]  bist_fail_map_o,

    output wire        evt_corr_o,
    output wire        evt_uncorr_o,
    output wire        evt_scrub_corr_o,
    output wire        err_o
);

    // the page an access actually lands in: the debugger's flat address
    // wins for its own access; the CPU rides the page register
    wire [3:0] sel_page = sba_flat_i ? adr_i[15:12] : page_i;

    wire [31:0] rdt_w   [0:PAGES-1];
    wire        ack_w   [0:PAGES-1];
    wire        busy_w  [0:PAGES-1];
    wire        pass_w  [0:PAGES-1];
    wire [15:0] fcnt_w  [0:PAGES-1];
    wire [9:0]  fadr_w  [0:PAGES-1];
    wire [4:0]  fmap_w  [0:PAGES-1];
    wire [PAGES-1:0] corr_v, uncorr_v, scrub_v, err_v;

    genvar g;
    generate
        for (g = 0; g < PAGES; g = g + 1) begin : g_page
            wire hit = (sel_page == g[3:0]);
            zirh_sram39 #(.SCRUB_DIV_LOG2(SCRUB_DIV_LOG2)) u_page (
                .clk(clk), .rst_n(rst_n),
                .scrub_en_i(scrub_en_i),
                .cyc_i(cyc_i & hit),
                .adr_i({20'd0, adr_i[11:0]}),
                .dat_i(dat_i), .sel_i(sel_i), .we_i(we_i),
                .rdt_o(rdt_w[g]), .ack_o(ack_w[g]),
                .evt_corr_o(corr_v[g]), .evt_uncorr_o(uncorr_v[g]),
                .evt_scrub_corr_o(scrub_v[g]),
                .err_o(err_v[g]),
                .bist_start_i(bist_start_i & hit),
                .bist_mode_i(bist_mode_i),
                .bist_busy_o(busy_w[g]), .bist_pass_o(pass_w[g]),
                .bist_fail_cnt_o(fcnt_w[g]), .bist_fail_adr_o(fadr_w[g]),
                .bist_fail_map_o(fmap_w[g]));
        end
    endgenerate

    localparam integer PW = (PAGES <= 1) ? 1 :
                            (PAGES <= 2) ? 1 :
                            (PAGES <= 4) ? 2 :
                            (PAGES <= 8) ? 3 : 4;
    wire [PW-1:0] mux_page = sel_page[PW-1:0];

    assign rdt_o           = rdt_w[mux_page];
    assign ack_o           = ack_w[mux_page];
    assign bist_busy_o     = busy_w[mux_page];
    assign bist_pass_o     = pass_w[mux_page];
    assign bist_fail_cnt_o = fcnt_w[mux_page];
    assign bist_fail_adr_o = fadr_w[mux_page];
    assign bist_fail_map_o = fmap_w[mux_page];

    assign evt_corr_o       = |corr_v;
    assign evt_uncorr_o     = |uncorr_v;
    assign evt_scrub_corr_o = |scrub_v;
    assign err_o            = |err_v;

endmodule

`default_nettype wire
