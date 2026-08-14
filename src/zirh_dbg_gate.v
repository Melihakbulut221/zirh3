// =============================================================================
// ZIRH product program P2 - the debug isolation gate and flight lock
// zirh_dbg_gate.v
//
// docs/DEBUG-DFT.md, requirement F27: the debug module is untrusted
// logic. This gate is the boundary between the debug domain and the
// system - the ONLY path any debug intent may take toward the core or
// the bus - and it is built so that every failure mode lands on
// LOCKED:
//
//   * the lock is latched from a strap pin ONCE, at reset release
//     (product: a fuse drives the strap); wiggling the pin afterward
//     changes nothing - there is no software unlock, because a
//     register that can unlock is a register an upset can flip
//   * every debug-to-system signal is forced inert while locked
//   * the latch is TMR; a voter mismatch reports on err_o and the
//     vote itself fails toward locked (2-of-3 of a register whose
//     only legal transition is toward lock cannot drift open)
//
// The gate deliberately knows nothing about the debug module behind
// it (riscv-dbg or anything else): it gates level/valid signals and
// masks strobes. Integration wires every dm_* through here; nothing
// else from the debug domain may touch the system netlist - that is
// a tmr-guard-style structural check at the dedicated-chip step.
// =============================================================================

`default_nettype none

module zirh_dbg_gate (
    input  wire        clk,
    input  wire        rst_n,

    // strap: 1 = debug permitted (bench), 0 = locked (flight fuse).
    // Sampled in the first cycle after reset release, then dead.
    input  wire        unlock_strap_i,

    // from the debug domain (untrusted)
    input  wire        dm_debug_req_i,   // halt request toward the core
    input  wire        dm_ndmreset_i,    // debug-initiated reset request
    input  wire        dm_sba_cyc_i,     // system bus access master
    input  wire [31:0] dm_sba_adr_i,
    input  wire [31:0] dm_sba_dat_i,
    input  wire        dm_sba_we_i,

    // toward the system (inert-when-locked)
    output wire        debug_req_o,
    output wire        ndmreset_o,
    output wire        sba_cyc_o,
    output wire [31:0] sba_adr_o,
    output wire [31:0] sba_dat_o,
    output wire        sba_we_o,

    output wire        locked_o,
    output wire        err_o
);

    // --- the armed latch ----------------------------------------------------
    // TMR register with a one-way arming FSM: S_SAMPLE (one cycle,
    // reads the strap) -> S_OPEN or S_LOCKED, both terminal. The
    // safe-state trap and every illegal encoding land on S_LOCKED.
    localparam [1:0] S_SAMPLE = 2'd0, S_OPEN = 2'd1, S_LOCKED = 2'd2;

    wire [1:0] st_q;
    reg  [1:0] st_d;
    wire       st_err;
    zirh_tmr_reg #(.WIDTH(2)) u_st (
        .clk(clk), .rst_n(rst_n), .en_i(1'b1), .d_i(st_d),
        .q_o(st_q), .err_o(st_err));

    always @* begin
        case (st_q)
            S_SAMPLE: st_d = unlock_strap_i ? S_OPEN : S_LOCKED;
            S_OPEN:   st_d = S_OPEN;
            S_LOCKED: st_d = S_LOCKED;
            default:  st_d = S_LOCKED;   // trap: fail toward locked
        endcase
    end

    // inert during the sample cycle too: the gate opens one cycle
    // after reset at the earliest, never before the strap is latched
    wire open_now = (st_q == S_OPEN);

    assign locked_o = ~open_now;

    // --- the boundary -------------------------------------------------------
    // ANDs, not muxes: a mux select upset could pass the live value;
    // an AND with a voted 0 is dead. Data buses are masked as well -
    // a locked gate leaks not even addresses.
    assign debug_req_o = dm_debug_req_i & open_now;
    assign ndmreset_o  = dm_ndmreset_i  & open_now;
    assign sba_cyc_o   = dm_sba_cyc_i   & open_now;
    assign sba_we_o    = dm_sba_we_i    & open_now;
    assign sba_adr_o   = dm_sba_adr_i   & {32{open_now}};
    assign sba_dat_o   = dm_sba_dat_i   & {32{open_now}};

    `include "zirh_assert.vh"
    // the boundary's whole contract, restated where it lives
    `ZIRH_ASSERT(a_locked_inert,
                 !locked_o || (!debug_req_o && !ndmreset_o
                               && !sba_cyc_o && !sba_we_o))

    assign err_o = st_err;

endmodule

`default_nettype wire
