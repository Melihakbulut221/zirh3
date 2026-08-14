// =============================================================================
// ZIRH-3 - power-on reset + independent RO clock source
// src/zirh_por_ro.v
//
// The genuinely-new dedicated-die silicon docs/SCOPE.md names: on the
// TT harness ZIRH-2 got its reset and its observer clock handed to it;
// a standalone die must MAKE them. This block does two jobs a padframe
// cannot:
//
//   1. POR / brown-out conditioning: hold the system in reset until the
//      raw pad reset is released AND a power-good level is asserted AND
//      a fixed settle counter has elapsed, then release through a
//      2-flop synchronizer. A brown-out (pwr_good_i drop) re-arms the
//      whole sequence. This is the reset the SoC and every block sees.
//
//   2. An INDEPENDENT ring-oscillator clock for the clock-loss observer.
//      zirh_clkobs needs a clock that keeps running when the main clock
//      dies; on a dedicated die that clock is a hand-instantiated ring,
//      not a pin. Same behavioral-vs-cell split as zirh_env_ro: the
//      simulation gets a divided-clk stand-in (the control path is what
//      sim proves), the SG13G2 ASIC synth gets the real inverter ring.
//
// Both are the substrate zirh3_memsys's ro_clk/ro_rst_n and the future
// SoC's reset attach to. Verified by an elaboration + sequence smoke
// (test/tb_por_ro.v): reset stays asserted through the settle window,
// releases clean, re-arms on brown-out, and the RO clock toggles
// independently.
// =============================================================================

`default_nettype none

module zirh_por_ro #(
    parameter integer POR_CYCLES   = 64,   // settle count before release
    parameter integer RO_DIV_LOG2  = 2     // sim RO = clk / 2^(N+1)
) (
    input  wire clk,          // main clock (also the sim RO reference)
    input  wire rst_n_pad,    // raw pad reset, active low
    input  wire pwr_good_i,   // brown-out detector: 1 = supply in range

    output wire sys_rst_n_o,  // clean, synchronized system reset

    // the independent observer clock domain
    output wire ro_clk_o,
    output wire ro_rst_n_o
);

    // --- POR / brown-out sequence ------------------------------------------
    // arm-and-count: while the pad is asserted or power is bad, hold the
    // counter at zero and reset asserted. Once both are good, count up to
    // POR_CYCLES; release only at the top. Any dropout re-arms.
    localparam integer CW = $clog2(POR_CYCLES + 1);

    reg [1:0]     pad_sync;
    reg [1:0]     pg_sync;
    always @(posedge clk or negedge rst_n_pad) begin
        if (!rst_n_pad) begin
            pad_sync <= 2'b00;
            pg_sync  <= 2'b00;
        end else begin
            pad_sync <= {pad_sync[0], 1'b1};
            pg_sync  <= {pg_sync[0], pwr_good_i};
        end
    end
    wire inputs_good = pad_sync[1] & pg_sync[1];

    reg [CW-1:0] por_cnt;
    reg          por_done;
    always @(posedge clk or negedge rst_n_pad) begin
        if (!rst_n_pad) begin
            por_cnt  <= {CW{1'b0}};
            por_done <= 1'b0;
        end else if (!inputs_good) begin        // brown-out re-arms
            por_cnt  <= {CW{1'b0}};
            por_done <= 1'b0;
        end else if (por_cnt == POR_CYCLES[CW-1:0]) begin
            por_done <= 1'b1;
        end else begin
            por_cnt <= por_cnt + 1'b1;
        end
    end

    assign sys_rst_n_o = por_done;

    // --- independent RO clock ----------------------------------------------
`ifdef ZIRH_SIM_ENV
`define ZIRH_POR_BEHAV
`endif
`ifdef SYNTH
`define ZIRH_POR_BEHAV
`endif

`ifdef ZIRH_POR_BEHAV
    // behavioral stand-in: a divided main clock, so the observer sees a
    // free-running domain in simulation. The real frequency only exists
    // in silicon; the control path (handoff, reset) is what sim proves.
    reg [RO_DIV_LOG2:0] ro_div;
    always @(posedge clk or negedge rst_n_pad)
        if (!rst_n_pad) ro_div <= {(RO_DIV_LOG2+1){1'b0}};
        else            ro_div <= ro_div + 1'b1;
    assign ro_clk_o = ro_div[RO_DIV_LOG2];
`else
    localparam integer STAGES = 32;   // even; NAND supplies the odd inversion
    wire [STAGES:0] n;
    (* keep *) sg13g2_nand2_1 u_gate (.A(1'b1), .B(n[STAGES]), .Y(n[0]));
    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : g_inv
            (* keep *) sg13g2_inv_1 u_inv (.A(n[i]), .Y(n[i+1]));
        end
    endgenerate
    assign ro_clk_o = n[STAGES];
`endif

    // the observer's reset in its own domain: released one RO edge after
    // the system reset, so the observer starts from a known state
    reg [1:0] ro_rst_sync;
    always @(posedge ro_clk_o or negedge por_done) begin
        if (!por_done) ro_rst_sync <= 2'b00;
        else           ro_rst_sync <= {ro_rst_sync[0], 1'b1};
    end
    assign ro_rst_n_o = ro_rst_sync[1];

endmodule

`default_nettype wire
