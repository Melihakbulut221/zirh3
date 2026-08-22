// =============================================================================
// ZIRH - the proof toolchain's own self-test (Cycle 39)
// formal/f_selftest.sv
//
// A three-bit counter over a free input, and the deliberately FALSE
// claim that it never reaches three. Every stage in scripts/formal.sh
// is worthless if the toolchain silently drops assertions, and that
// is not hypothetical: a yosys new enough to emit $check cells writes
// SMT2 whose assertions the older solver front-end never queries -
// BMC then reports PASSED over a design with no properties at all,
// which is indistinguishable in a log from a theorem.
//
// So the suite proves its own instrument first: this file MUST be
// refuted. If the solver ever agrees that the counter cannot reach
// three, the tools are lying and every proof after it is void.
// =============================================================================

`default_nettype none

module f_selftest (input wire clk, input wire step_i);
    reg       v = 1'b0;
    reg [2:0] c = 3'd0;
    always @(posedge clk) begin
        v <= 1'b1;
        if (step_i) c <= c + 3'd1;
    end
    always @(posedge clk)
        if (v) a_selftest_must_fail: assert (c != 3'd3);
endmodule

`default_nettype wire
