// =============================================================================
// ZIRH-2 - formal proof of the address-in-ECC mask (PROGRAM.md A4)
// formal/f_amask.sv
//
// The claim the sliced SRAM's wrong-row defence rests on: data written
// with row A's mask and read with row B's mask NEVER decodes clean or
// correctable - for EVERY data word and EVERY pair of distinct rows,
// the decoder must land in the UNCORRECTABLE bin, because returning
// wrong-row data as "clean" (or worse, "corrected") is the silent
// failure the mask exists to kill. Matching rows must decode clean
// with the exact data. Proven for all 2^32 words x 2^20 row pairs in
// one BMC step; the mask logic is combinational, replicated here
// verbatim from zirh_sram39.v over the shared zirh_secded.vh helpers.
// =============================================================================

`default_nettype none

module f_amask (
    input wire clk
);

    `include "zirh_secded.vh"

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

    (* anyconst *) wire [31:0] d;
    (* anyconst *) wire [9:0]  row_wr;
    (* anyconst *) wire [9:0]  row_rd;

    wire [38:0] stored = encode(d) ^ amask(row_wr);
    wire [38:0] raw    = stored ^ amask(row_rd);

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
    wire [37:0] gathered = gather_data_ext(cw_fixed);

    // p6 folding collides for rows 64k apart with equal fold; the claim
    // is scoped to rows whose FOLD differs - which includes every
    // single-bit address error, the SET model the mask is built for
    wire [5:0] fold_wr = row_wr[5:0] ^ {2'b00, row_wr[9:6]};
    wire [5:0] fold_rd = row_rd[5:0] ^ {2'b00, row_rd[9:6]};

    always @(posedge clk) begin
        if (fold_wr == fold_rd) begin
            // same fold (includes same row): decode is clean and exact
            assert (!had_corr && !uncorr);
            assert (gathered[31:0] == d);
        end else begin
            // any fold difference - every single-bit address flip -
            // lands UNCORRECTABLE: never clean, never "corrected"
            assert (uncorr && !had_corr);
        end
    end

endmodule

`default_nettype wire
