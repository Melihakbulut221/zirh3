// =============================================================================
// ZIRH-3 - formal harness for the boot controller's rulings (Cycle 39)
// formal/f_boot.sv
//
// The loader decides what code this die runs; it is the program's
// trust anchor and until now it carried tests but no theorem. This
// harness gives zirh_boot_ctrl the same treatment the debug lock and
// the SECDED contract already had: every input FREE - the byte
// stream, the strap, the signature verdict, the watchdog, the bus
// answers - and the module's own invariants (src/zirh_boot_ctrl.v,
// the FORMAL block) proven by unbounded induction over the whole
// reachable state space.
//
// PROTECT=0 on purpose. The TMR containment theorem (f_ring) already
// proves the voted register carries the machine under any
// one-replica-per-cycle upset stream; this proof is about the LOGIC.
// The two compose: correct logic, and a register that keeps it.
//
// BANK_WORDS is small here because the bank index is the only thing
// that scales with it - every property proven is width-independent,
// and a narrow index is what lets induction close instead of drowning
// in a 13-bit counter.
//
// The covers are the anti-vacuity gate: a loader that never rules
// satisfies every safety property for free, so the proof is only
// worth its log line if a real commit AND a real refusal are both
// reachable in the same free-input machine.
// =============================================================================

`default_nettype none

module f_boot (
    input wire        clk,
    input wire [1:0]  strap,
    input wire        st_valid,
    input wire [7:0]  st_data,
    input wire        sig_ok,
    input wire        signon,
    input wire        wd_fail,
    input wire [31:0] m_rdt,
    input wire        m_ack
);

    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    wire rst_n = f_past_valid;

    wire        st_ready, m_cyc, m_we, boot_sel, bank, acc, rej, err;
    wire [31:0] m_adr, m_dat;

    zirh_boot_ctrl #(.BANK_WORDS(8), .PROTECT(0)) u_boot (
        .clk(clk), .rst_n(rst_n),
        .strap_i(strap),
        .st_valid_i(st_valid), .st_data_i(st_data), .st_ready_o(st_ready),
        .sig_ok_i(sig_ok), .signon_i(signon), .wd_fail_i(wd_fail),
        .m_cyc_o(m_cyc), .m_adr_o(m_adr), .m_dat_o(m_dat), .m_we_o(m_we),
        .m_rdt_i(m_rdt), .m_ack_i(m_ack),
        .boot_sel_o(boot_sel), .bank_o(bank),
        .evt_accept_o(acc), .evt_reject_o(rej), .err_o(err));

`ifndef F_COVER
    // a verdict is one verdict: the loader never accepts and refuses
    // the same image in the same cycle
    always @(posedge clk) if (rst_n)
        a_one_verdict: assert (!(acc && rej));
`else
    // the machine can actually rule, both ways - without these the
    // safety theorems above would be guarding nothing
    always @(posedge clk) if (rst_n) begin
        c_commit: cover (acc);
        c_refuse: cover (rej);
    end
`endif

endmodule

`default_nettype wire
