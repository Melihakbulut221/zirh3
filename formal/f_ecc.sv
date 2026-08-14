// =============================================================================
// ZIRH-2 - formal proof of the SECDED contract on the shipped ECC RAM
// formal/f_ecc.sv
//
// The register file lives here; if this block lies, every campaign
// number above it is fiction. Proven against the SHIPPED encode and
// decode (zirh_ecc_ram.v compiled with -DFORMAL, which adds only an
// XOR fault port into the read view - zero silicon, zero simulation
// divergence):
//
//   ROUNDTRIP    write any word, read it back clean: equal, no events.
//   CORRECTION   corrupt ANY ONE of the 39 stored bits (data, Hamming
//                parity, or the overall parity bit): the read still
//                returns the written word, evt_corr pulses, evt_uncorr
//                does not. All 39 positions, all 2^32 words, one proof.
//   DETECTION    corrupt ANY TWO bits: evt_uncorr pulses, evt_corr
//                does not - the miscorrection space is empty.
//   MERGE        a partial (byte-select) write performs read-correct-
//                merge-reencode: with any single stored-bit corruption
//                present during the merge, the resulting word is the
//                corrected old bytes merged with the new bytes - the
//                RMW path cannot launder a corrupted byte back in.
//
// The fault is injected into the read VIEW with a constant mask, which
// models persistent storage corruption exactly for the read under
// test; the scrub-rewrites-storage behaviour itself is exercised by
// the cocotb suites (this harness would see a healed word trivially).
//
// Bounded proof: the scenario is a fixed 5-phase transaction sequence,
// checked exhaustively over all words, all masks and all initial
// memory states by BMC to depth 12 (scripts/formal.sh).
// =============================================================================

`default_nettype none

module f_ecc (
    input wire clk
);

    // solver-chosen constants: the word under test, the fault mask, the
    // partial-write byte lane data and select
    (* anyconst *) wire [31:0] w_const;
    (* anyconst *) wire [38:0] c_const;
    (* anyconst *) wire [31:0] pw_const;
    (* anyconst *) wire [3:0]  sel_const;

    function automatic [6:0] ones39(input [38:0] v);
        integer i;
        begin
            ones39 = 0;
            for (i = 0; i < 39; i = i + 1)
                ones39 = ones39 + {6'b0, v[i]};
        end
    endfunction

    wire [6:0] cbits = ones39(c_const);

    // --- phase sequencer ----------------------------------------------------
    //  0 reset | 1 write W | 2 corrupted read | 3 clean read (events of
    //  phase 2 visible) | 4 partial write under corruption | 5 clean read
    reg [2:0] ph = 3'd0;
    always @(posedge clk) if (ph != 3'd6) ph <= ph + 3'd1;

    wire rst_n = (ph != 3'd0);
    wire cyc   = (ph == 3'd1) | (ph == 3'd2) | (ph == 3'd3)
               | (ph == 3'd4) | (ph == 3'd5);
    wire we    = (ph == 3'd1) | (ph == 3'd4);
    wire [3:0]  sel = (ph == 3'd1) ? 4'hF : sel_const;
    wire [31:0] dat = (ph == 3'd1) ? w_const : pw_const;
    wire [38:0] corrupt = ((ph == 3'd2) | (ph == 3'd4)) ? c_const : 39'd0;

    wire [31:0] rdt;
    wire        ack, corr, uncorr;

    zirh_ecc_ram u_ram (
        .clk(clk), .rst_n(rst_n),
        .cyc_i(cyc), .adr_i(32'h0), .dat_i(dat), .sel_i(sel),
        .we_i(we), .rdt_o(rdt), .ack_o(ack),
        .evt_corr_o(corr), .evt_uncorr_o(uncorr),
        .f_corrupt_i(corrupt)
    );

    // expected merge result: corrected old bytes where sel is low
    wire [31:0] merged_exp = {sel_const[3] ? pw_const[31:24] : w_const[31:24],
                              sel_const[2] ? pw_const[23:16] : w_const[23:16],
                              sel_const[1] ? pw_const[15:8]  : w_const[15:8],
                              sel_const[0] ? pw_const[7:0]   : w_const[7:0]};

    always @(posedge clk) begin
        // ROUNDTRIP + CORRECTION: the corrupted read returns the word
        if (ph == 3'd2 && cbits <= 7'd1)
            assert (rdt == w_const);

        // events of the phase-2 read, registered, visible in phase 3
        if (ph == 3'd3) begin
            if (cbits == 7'd0) assert (!corr && !uncorr);
            if (cbits == 7'd1) assert ( corr && !uncorr);
            if (cbits == 7'd2) assert (!corr &&  uncorr);
            // and the clean re-read still returns the word
            if (cbits <= 7'd1) assert (rdt == w_const);
        end

        // MERGE: after a partial write performed under a single stored-
        // bit corruption, the clean read returns corrected-old merged
        // with new - never a laundered corrupt byte
        if (ph == 3'd5 && cbits <= 7'd1)
            assert (rdt == merged_exp);
    end

    wire _unused = &{ack, rdt, 1'b0};

endmodule

`default_nettype wire
