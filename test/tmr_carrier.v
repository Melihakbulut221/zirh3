// ZIRH-3 - pilot B carrier: a plain 16-bit LFSR with zero protection.
// Small enough to read, stateful enough to prove the stitcher: after
// triplication every step must match the golden model, and a masked
// replica must not disturb the stream.
`default_nettype none
module tmr_carrier (
    input  wire        clk,
    input  wire        rst_n,
    output wire [15:0] q_o
);
    reg [15:0] q;
    always @(posedge clk) begin
        if (!rst_n) q <= 16'hACE1;
        else        q <= {q[14:0], q[15] ^ q[13] ^ q[12] ^ q[10]};
    end
    assign q_o = q;
endmodule
`default_nettype wire
