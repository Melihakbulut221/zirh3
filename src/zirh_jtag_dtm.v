// =============================================================================
// ZIRH-3 - JTAG TAP + RISC-V Debug Transport Module (F27, brief item 27)
// src/zirh_jtag_dtm.v
//
// The pin side of the debug interface: an IEEE 1149.1 TAP controller
// with the three data registers the RISC-V debug spec (0.13) gives a
// debugger - IDCODE, DTMCS and DMI - translating JTAG scans into DMI
// register accesses toward the Debug Module. Everything DOWNSTREAM of
// here goes through zirh_dbg_gate, whose absorbing flight lock is
// formally proven; this block is deliberately upstream of trust.
//
// Hardening posture, stated honestly:
//   * TAP state and IR are TMR (zirh_tmr_reg on tck): an upset here
//     could otherwise walk the FSM into Shift-DR and clock garbage
//     into a DMI transaction.
//   * The DR shift registers are PLAIN: a corrupted scan is a corrupted
//     debugger request, and every request still faces the gate and the
//     DM's own checks - the same transport-vs-boundary philosophy as
//     the ISP receiver.
//   * The DMI request crosses tck -> clk through a toggle/ack 2FF
//     handshake; a busy overrun reports sticky DMISTAT=3 per spec.
//
// IR (5 bits): 0x01 IDCODE, 0x10 DTMCS, 0x11 DMI; all others select
// BYPASS. IDCODE = 0x5A1R_H3D1-style constant below (LSB must be 1).
// =============================================================================

`default_nettype none

module zirh_jtag_dtm #(
    parameter [31:0] IDCODE = 32'h1Z3D_0001 // overridden below; LSB=1
) (
    // JTAG pins (tck domain)
    input  wire        tck,
    input  wire        trst_n,      // async TAP reset (tie high if unused)
    input  wire        tms,
    input  wire        tdi,
    output reg         tdo,

    // system side (clk domain)
    input  wire        clk,
    input  wire        rst_n,

    // DMI master toward the Debug Module
    output reg  [6:0]  dmi_adr_o,
    output reg  [31:0] dmi