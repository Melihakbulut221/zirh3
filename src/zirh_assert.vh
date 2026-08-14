// =============================================================================
// ZIRH - embedded assertion library, one property source (H44)
// src/zirh_assert.vh
//
// The same macro text lands in BOTH consumers:
//   simulation  compile with -DZIRH_ASSERTIONS: violations $fatal the
//               run, so every cocotb suite polices the invariants
//               continuously, not just at its own checkpoints
//   formal      compile with -DFORMAL: the macro becomes a formal
//               assert and the property joins the proof obligations
//
// Without either define the macros vanish - the ASIC netlist carries
// zero assertion logic. Harness-level THEOREMS (escape window, SECDED
// contract, lock trapdoor) stay in formal/ by design: they need free
// inputs and golden models a module cannot host. What lives here are
// the INVARIANTS a module can state about itself.
// =============================================================================

`ifdef FORMAL
  `define ZIRH_ASSERT(name, cond) \
      always @(posedge clk) if (rst_n) name: assert (cond);
`elsif ZIRH_ASSERTIONS
  `define ZIRH_ASSERT(name, cond) \
      always @(posedge clk) if (rst_n && !(cond)) \
          $fatal(1, `"zirh assertion name failed`");
`else
  `define ZIRH_ASSERT(name, cond)
`endif
