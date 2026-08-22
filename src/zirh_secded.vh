// =============================================================================
// ZIRH-2 - shared Hamming SECDED helpers (include)
// src/zirh_secded.vh
//
// Extracted verbatim from zirh_ecc_ram.v so the SRAM wrapper of the
// product program stores EXACTLY the same codeword the flop RAM does -
// one encode, one syndrome, two memories. The formal SECDED proof
// (formal/f_ecc.sv) runs against the flop RAM that includes this file,
// so any edit here is caught by the proof in CI.
//
// Codeword positions 1..38: parity at the powers of two (1,2,4,8,16,
// 32), data scattered over the rest, overall parity as bit [38] of
// the stored 39-bit word.
//
// The address-in-ECC mask lives here too, and it lives here for a
// reason found the hard way: it used to exist twice, once in the SRAM
// wrapper at twelve address bits and once retyped inside its own
// formal harness at TEN, with a comment claiming the two were
// identical at the default depth. They were not - the built bank is
// 4096 deep, so all twelve bits are live - and the proof was
// therefore proving a function the die does not contain. One source
// now: the harness proves what the RTL folds, because it is the same
// text.
// =============================================================================

    function [38:1] place_data;
        input [31:0] d;
        integer pos, k;
        begin
            place_data = 38'b0;
            k = 0;
            for (pos = 1; pos <= 38; pos = pos + 1)
                if (pos != 1 && pos != 2 && pos != 4 &&
                    pos != 8 && pos != 16 && pos != 32) begin
                    place_data[pos] = d[k];
                    k = k + 1;
                end
        end
    endfunction

    function [37:0] gather_data_ext;   // returns {6'b0, data[31:0]} packing
        input [38:1] cw;
        integer pos, k;
        reg [31:0] d;
        begin
            d = 32'b0;
            k = 0;
            for (pos = 1; pos <= 38; pos = pos + 1)
                if (pos != 1 && pos != 2 && pos != 4 &&
                    pos != 8 && pos != 16 && pos != 32) begin
                    d[k] = cw[pos];
                    k = k + 1;
                end
            gather_data_ext = {6'b0, d};
        end
    endfunction

    function [5:0] syndrome_of;
        input [38:1] cw;
        integer pos, i;
        begin
            syndrome_of = 6'b0;
            for (i = 0; i < 6; i = i + 1)
                for (pos = 1; pos <= 38; pos = pos + 1)
                    if (((pos >> i) & 1) == 1)
                        syndrome_of[i] = syndrome_of[i] ^ cw[pos];
        end
    endfunction

    function [38:0] encode;
        input [31:0] d;
        reg [38:1] cw;
        reg [5:0]  syn;
        integer i;
        begin
            cw  = place_data(d);
            syn = syndrome_of(cw);      // parity slots are 0: syn = parities
            for (i = 0; i < 6; i = i + 1)
                cw[(1 << i)] = syn[i];
            encode = {^cw, cw};         // [38] overall parity, [37:0] cw
        end
    endfunction


// -----------------------------------------------------------------------------
// Address-in-ECC mask: fold the row into six bits, scatter them onto
// the parity positions and the overall bit. Data written under row A
// and read under row B lands UNCORRECTABLE whenever the folds differ -
// which covers every single-bit address error, the fault model the
// mask exists for. Callers zero-extend narrower rows.
// -----------------------------------------------------------------------------
function [38:0] amask;
    input [11:0] a;
    reg [5:0] p6;
    integer i;
    begin
        p6 = a[5:0] ^ a[11:6];
        amask = 39'd0;
        for (i = 0; i < 6; i = i + 1)
            amask[(1 << i) - 1] = p6[i];
        amask[38] = ^p6;
    end
endfunction
