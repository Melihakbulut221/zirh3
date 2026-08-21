// =============================================================================
// ZIRH-3 - the TMR'd FIFO primitive (Cycle 35)
// src/zirh_fifo.v
//
// The yardstick puts a 16-word FIFO behind every serial port; this
// die's peripherals hand bytes over one at a time. This primitive
// closes that gap once, for all of them: a synchronous FIFO whose
// EVERY bit of state - both pointers and the whole storage array -
// lives in zirh_tmr_reg, because a queue that forgets its depth in
// flight corrupts every byte behind the fault, not just one.
//
// The laws:
//   - a push to a full FIFO is REFUSED (full_o already said no; the
//     caller decides whether refusal is an error worth a flag)
//   - a pop from an empty FIFO is refused the same way
//   - rdat_o always shows the oldest entry combinationally; pop
//     advances to the next on the clock
//   - level_o = pushes minus pops, the pointer difference, usable
//     as both a fill gauge and the empty/full derivation
//
// Storage is one flat vector indexed with variable part-selects -
// the one array idiom the whole tool chain of this repository reads
// identically (iverilog, yosys and the linter alike).
// =============================================================================

`default_nettype none

module zirh_fifo #(
    parameter WIDTH      = 8,
    parameter DEPTH_LOG2 = 4
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  wr_i,
    input  wire [WIDTH-1:0]      wdat_i,
    input  wire                  rd_i,
    output wire [WIDTH-1:0]      rdat_o,

    output wire                  empty_o,
    output wire                  full_o,
    output wire [DEPTH_LOG2:0]   level_o,

    output wire                  err_o
);

    localparam DEPTH = 1 << DEPTH_LOG2;

    // one extra pointer bit tells full from empty at equal indices
    wire [DEPTH_LOG2:0] wptr_q, rptr_q;
    wire                e_wptr, e_rptr;

    wire push = wr_i & ~full_o;
    wire pop  = rd_i & ~empty_o;

    zirh_tmr_reg #(.WIDTH(DEPTH_LOG2 + 1)) u_wptr (
        .clk(clk), .rst_n(rst_n),
        .en_i(push), .d_i(wptr_q + {{DEPTH_LOG2{1'b0}}, 1'b1}),
        .q_o(wptr_q), .err_o(e_wptr));
    zirh_tmr_reg #(.WIDTH(DEPTH_LOG2 + 1)) u_rptr (
        .clk(clk), .rst_n(rst_n),
        .en_i(pop), .d_i(rptr_q + {{DEPTH_LOG2{1'b0}}, 1'b1}),
        .q_o(rptr_q), .err_o(e_rptr));

    assign level_o = wptr_q - rptr_q;
    assign empty_o = (level_o == {(DEPTH_LOG2 + 1){1'b0}});
    assign full_o  = (level_o == {1'b1, {DEPTH_LOG2{1'b0}}});

    wire [DEPTH*WIDTH-1:0] mem_q;
    wire [DEPTH-1:0]       e_mem;
    genvar gi;
    generate
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin : g_mem
            zirh_tmr_reg #(.WIDTH(WIDTH)) u_mem (
                .clk(clk), .rst_n(rst_n),
                .en_i(push & (wptr_q[DEPTH_LOG2-1:0] == gi[DEPTH_LOG2-1:0])),
                .d_i(wdat_i),
                .q_o(mem_q[gi*WIDTH +: WIDTH]),
                .err_o(e_mem[gi]));
        end
    endgenerate

    assign rdat_o = mem_q[rptr_q[DEPTH_LOG2-1:0]*WIDTH +: WIDTH];

    assign err_o = e_wptr | e_rptr | (|e_mem);

endmodule

`default_nettype wire
