// =============================================================================
// ZIRH-3 - the SRAM DUT experiment (PROGRAM.md A6, brief item 6)
// src/zirh_sram_dut.v
//
// The raw-cross-section instrument: five BARE RM_IHPSG13 macros - no
// SECDED, no scrubber, no voting - driven by the proven pattern engine
// and observed at the failure level, so a beam campaign reads the
// UNPROTECTED macro's SEU/MBU behavior directly. This is the second
// evidence leg the brief names: no published beam data exists for these
// open-PDK macros, so this dataset alone is citable.
//
// It is the deliberate opposite of zirh_sram39: same five macros, but
// here nothing corrects them. The engine writes a pattern (march c-,
// checkerboard, read-scan), reads it back, and every mismatch is a raw
// event. The record the DUT board logs is (fail_adr, fail_map): WHICH
// address failed and WHICH of the five macros failed there - the
// per-macro bit map that lets the ground analysis separate single-bit
// upsets from multi-bit upsets within one physical macro (the MBU
// correlation the brief asks for). Static vs dynamic is the scan mode;
// raw address logging is fail_adr streamed out, not aggregated on chip.
//
// Reuses zirh_sram39_slice (the proven macro binding) and
// zirh_sram_bist (the proven pattern engine) unchanged - integration,
// not new datapath, exactly like the memory subsystem.
// =============================================================================

`default_nettype none

module zirh_sram_dut (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_i,      // launch a scan
    input  wire [1:0]  mode_i,       // 0 march c-, 1 cb fill, 2 read-scan

    output wire        busy_o,
    output wire        pass_o,       // clean scan, no macro failed
    output wire [15:0] fail_cnt_o,   // total mismatches this scan
    output wire [9:0]  fail_adr_o,   // address of the latest failure - the
                                     // raw log the DUT board timestamps
    output wire [4:0]  fail_map_o,   // which of the 5 macros failed there:
                                     // the per-macro MBU map
    output wire        err_o         // engine TMR mismatch
);

    // --- the five bare macros (no SECDED, no scrubber) ----------------------
    wire        b_en, b_men, b_wen, b_ren;
    wire [9:0]  b_adr;
    wire [7:0]  b_din;
    wire [7:0]  q [0:4];

    genvar k;
    generate
        for (k = 0; k < 5; k = k + 1) begin : g_dut
            zirh_sram39_slice u_slice (
                .clk      (clk),
                .men      (1'b0),      // no functional port: the DUT is the
                .wen      (1'b0),      // engine's alone during the experiment
                .ren      (1'b0),
                .adr      (10'd0),
                .d        (8'd0),
                .q        (q[k]),
                .bist_en  (b_en),
                .bist_men (b_men),
                .bist_wen (b_wen),
                .bist_ren (b_ren),
                .bist_adr (b_adr),
                .bist_din (b_din)
            );
        end
    endgenerate

    // --- the pattern engine, TMR'd (the engine is protected; the macros
    //     under test are deliberately not) ----------------------------------
    zirh_sram_bist #(.ADDR_W(10)) u_engine (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_i    (start_i),
        .mode_i     (mode_i),
        .q0_i       (q[0]),
        .q1_i       (q[1]),
        .q2_i       (q[2]),
        .q3_i       (q[3]),
        .q4_i       (q[4]),
        .bist_en_o  (b_en),
        .bist_men_o (b_men),
        .bist_wen_o (b_wen),
        .bist_ren_o (b_ren),
        .bist_adr_o (b_adr),
        .bist_din_o (b_din),
        .busy_o     (busy_o),
        .pass_o     (pass_o),
        .fail_cnt_o (fail_cnt_o),
        .fail_adr_o (fail_adr_o),
        .fail_map_o (fail_map_o),
        .err_o      (err_o)
    );

endmodule

`default_nettype wire
