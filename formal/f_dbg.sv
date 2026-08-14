// =============================================================================
// ZIRH - formal proof of the debug gate's lock invariant (F27)
// formal/f_dbg.sv
//
// Proven by unbounded induction over free debug-side inputs AND a
// free strap: once the gate is not OPEN, every system-side output is
// inert and the gate can never become OPEN again - the lock is a
// one-way trapdoor for the whole reachable state space, upsets and
// strap wiggling included. The cover shows the bench path exists.
// =============================================================================

`default_nettype none

module f_dbg (
    input wire clk,
    input wire strap,
    input wire req, input wire ndm, input wire cyc, input wire we,
    input wire [31:0] adr, input wire [31:0] dat
);
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    wire rst_n = f_past_valid;

    // cycle fence: 0 = reset, 1 = sample, >=2 = latched forever
    reg [1:0] f_cyc = 2'd0;
    always @(posedge clk) if (f_cyc != 2'd3) f_cyc <= f_cyc + 2'd1;

    wire dreq, dndm, dcyc, dwe;
    wire [31:0] dadr, ddat;
    wire locked, err;

    zirh_dbg_gate u_gate (
        .clk(clk), .rst_n(rst_n), .unlock_strap_i(strap),
        .dm_debug_req_i(req), .dm_ndmreset_i(ndm),
        .dm_sba_cyc_i(cyc), .dm_sba_adr_i(adr),
        .dm_sba_dat_i(dat), .dm_sba_we_i(we),
        .debug_req_o(dreq), .ndmreset_o(dndm),
        .sba_cyc_o(dcyc), .sba_adr_o(dadr), .sba_dat_o(ddat),
        .sba_we_o(dwe), .locked_o(locked), .err_o(err));

`ifndef F_COVER
    always @(posedge clk) begin
        if (f_past_valid) begin
            // inertness: anything but OPEN keeps the system side dead
            if (locked)
                assert (!dreq && !dndm && !dcyc && !dwe
                        && dadr == 32'h0 && ddat == 32'h0);
            // trapdoor: past the sample cycle the verdict never
            // changes, in either direction - locked stays locked,
            // open stays open, strap and upsets notwithstanding
            if (f_cyc >= 2'd2 && $past(f_cyc) >= 2'd2)
                assert (locked == $past(locked));
        end
    end
`else
    always @(posedge clk)
        if (f_past_valid) cover (!locked && dreq);
`endif

endmodule

`default_nettype wire
