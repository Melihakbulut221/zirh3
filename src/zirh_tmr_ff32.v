// =============================================================================
// ZIRH-2 - concrete wrapper for one constrained-chain replica
// zirh_tmr_ff32.v
//
// The A-chain of zirh_hk instantiates this named module instead of the
// parameterized zirh_tmr_ff directly, so that at hardening time the three
// instances can be bound to a pre-hardened macro (LibreLane MACROS object,
// mechanism proven in docs/ZIRH2-SCOPE.md phase 4) and pinned to separated
// coordinates. In simulation and unconstrained synthesis it is identical
// to zirh_tmr_ff #(32).
// =============================================================================

`default_nettype none

(* keep_hierarchy *)
module zirh_tmr_ff32 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [31:0] d_i,
    output wire [31:0] q_o
);

  zirh_tmr_ff #(
      .WIDTH (32)
  ) u_core (
      .clk   (clk),
      .rst_n (rst_n),
      .d_i   (d_i),
      .q_o   (q_o)
  );

endmodule

`default_nettype wire
