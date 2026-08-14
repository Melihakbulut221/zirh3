// =============================================================================
// ZIRH-2 - formal proof of the escape window on the voted-feedback ring
// formal/f_ring.sv
//
// The gate-level SEU sweep samples the escape window: 384 singles never
// escape, same-bit-same-cycle pairs always do. Sampling proves the
// cases tried; this harness proves the THEOREM the prediction rests on,
// by unbounded induction over every reachable state:
//
//   THEOREM (single-replica containment). Under an arbitrary infinite
//   stream of upsets - any number of bits per cycle, ANY bits, as long
//   as each cycle corrupts at most ONE replica - the voted output of
//   the ring equals the golden shift register in every bit of every
//   cycle. Not one escape, ever. This is strictly stronger than the
//   sweep's singles claim: even a multi-bit upset confined to one
//   replica is contained, and upsets may arrive every single cycle.
//
//   WITNESS (the escape exists). Drop the containment assumption for
//   one cycle - let one upset touch the same bit in TWO replicas - and
//   the solver produces the escape trace: the broken majority enters
//   the feedback, travels the ring and exits as a wrong output bit.
//   The BMC witness VCD is the mechanism drawn by an exhaustive tool
//   rather than a chosen testcase.
//
// The ring here is the shipped structure: the same zirh_tmr_ff replica
// primitive from src/zirh_tmr_lib.v, the same 2-of-3 vote, the same
// voted-feedback shift. Upsets are modeled at the capture inputs - a
// flip at D is the state upset the sweep forces at Q, one cycle
// earlier. N is a parameter; the proof is run at several N including
// the shipping 32 (the induction is N-independent, the runs are belt
// and braces).
//
//   containment : yosys -sv -formal, BMC + k-induction  (assert)
//   witness     : same netlist compiled with -DF_PAIR   (cover)
//
// scripts/formal.sh runs both with yosys-smtbmc + z3.
// =============================================================================

`default_nettype none

module f_ring #(
    parameter N = 8
) (
    input wire clk,
    // free formal inputs: the solver picks these every cycle
    input wire in_bit,
    input wire [N-1:0] flip_a,
    input wire [N-1:0] flip_b,
    input wire [N-1:0] flip_c
);

    // --- reset protocol: cycle 0 in reset, free-running after -------------
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    wire rst_n = f_past_valid;

    // --- the ring as shipped ----------------------------------------------
    wire [N-1:0] qa, qb, qc;
    wire [N-1:0] voted = (qa & qb) | (qb & qc) | (qa & qc);
    wire [N-1:0] base  = {voted[N-2:0], in_bit};

    zirh_tmr_ff #(.WIDTH(N)) u_ff_a (
        .clk(clk), .rst_n(rst_n), .d_i(base ^ flip_a), .q_o(qa));
    zirh_tmr_ff #(.WIDTH(N)) u_ff_b (
        .clk(clk), .rst_n(rst_n), .d_i(base ^ flip_b), .q_o(qb));
    zirh_tmr_ff #(.WIDTH(N)) u_ff_c (
        .clk(clk), .rst_n(rst_n), .d_i(base ^ flip_c), .q_o(qc));

    // --- the golden ring: same pattern, no upsets --------------------------
    reg [N-1:0] shadow;
    always @(posedge clk) begin
        if (!rst_n) shadow <= {N{1'b0}};
        else        shadow <= {shadow[N-2:0], in_bit};
    end

`ifndef F_PAIR
    // --- containment: at most one replica corrupted per cycle -------------
    always @* begin
        assume ((flip_a == {N{1'b0}}) + (flip_b == {N{1'b0}})
                + (flip_c == {N{1'b0}}) >= 2'd2);
    end

    always @(posedge clk) begin
        if (f_past_valid) begin
            // helper invariant that makes the theorem 1-inductive: a
            // majority of replicas always equals the golden ring
            assert ((qa == shadow) + (qb == shadow) + (qc == shadow)
                    >= 2'd2);
            // the theorem: the voted output never differs from golden,
            // any bit, any cycle, under the upset stream
            assert (voted == shadow);
        end
    end
`else
    // --- witness: one same-bit two-replica upset, then silence ------------
    reg [N-1:0] f_mask;
    reg         f_fired;
    initial f_fired = 1'b0;
    always @(posedge clk) if (flip_a != {N{1'b0}}) f_fired <= 1'b1;

    always @* begin
        // the double hit is one-hot, hits a and b on the SAME bit, and
        // may happen in at most one cycle of the trace; the hit is
        // confined to the LOWER half of the ring so the witness must
        // show the broken majority TRAVELING through the voted
        // feedback to the output - the mechanism, not a lucky last-bit
        assume (flip_b == flip_a);
        assume (flip_c == {N{1'b0}});
        assume ((flip_a & (flip_a - 1'b1)) == {N{1'b0}});
        assume (flip_a[N-1:N/2] == {N/2{1'b0}});
        if (f_fired) assume (flip_a == {N{1'b0}});
    end

    // the escape: the wrong bit reaches the ring OUTPUT - the event the
    // ESC counter counts and the beam measures
    always @(posedge clk) begin
        if (f_past_valid)
            cover (voted[N-1] != shadow[N-1]);
    end
`endif

endmodule

`default_nettype wire
