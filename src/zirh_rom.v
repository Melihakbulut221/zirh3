// =============================================================================
// ZIRH-2 - mask ROM: 1 KB firmware, synthesized constants
// zirh_rom.v
//
// 256 x 32-bit words. Default contents come from src/rom_init.vh, a
// GENERATED include committed next to this file (fw/rom_gen.py emits it
// from the CI firmware build) - so every consumer of the RTL, from
// iverilog to the TT flow's Yosys, sees the same mask ROM with no
// parameter plumbing. The HEX parameter remains as a test override
// ($readmemh) for fixture images. With no write port the array
// synthesizes to pure combinational constants - inherently SEU-immune,
// which is why the firmware lives here and not in RAM.
//
// Two independent read ports, both combinational single-cycle:
//   * ibus: SERV instruction fetches, wired point to point (not through
//     the bus - instruction fetch must not compete with data traffic on a
//     single-master interconnect, and constants have no port conflicts)
//   * dbus: a bus slave like every other block, so firmware can read its
//     own image (checksum self-test at boot)
//
// ZIRH-2 memory map (bus slot = adr[14:12]):
//   slot 0  0x0000_0000  this ROM (1 KB)
//   slot 1  0x0000_1000  zirh_ecc_ram (64 B), stack top at 0x1040
//   slot 2  0x0000_2000  zirh_uart_regs
// =============================================================================

`default_nettype none

module zirh_rom #(
    parameter HEX = ""    // test override; empty = the committed rom_init.vh
) (
    input  wire        clk,   // SYNTH (FPGA twin) registered reads only
    // instruction port (SERV ibus, point to point)
    input  wire [31:0] i_adr_i,
    output wire [31:0] i_rdt_o,

    // data port (bus slave)
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    output wire [31:0] rdt_o,
    output wire        ack_o
);

    reg [31:0] mem [0:255];

    generate
        if (HEX != "") begin : g_load
            initial $readmemh(HEX, mem);
        end else begin : g_fw
            initial begin
                `include "rom_init.vh"
            end
        end
    endgenerate

`ifdef SYNTH
    // FPGA twin: register both read ports so yosys maps the 256x32 array
    // to block RAM instead of ~8 Kbit of LUTs - the fit lever the full
    // (5-interface) design needs on UP5K. The fetch side is timing-safe
    // by construction: the SoC's ibus_ack is already one cycle delayed
    // (ibus_cyc & ~ibus_ack), so a registered fetch delivers exactly on
    // the ack cycle SERV samples. The dbus side must delay its ACK to
    // match the registered data - a combinational ack here lets the CPU
    // sample one cycle early and the stale read corrupts the command
    // path (measured, the same failure the ASIC dbus experiment hit).
    // A twin/silicon delta, ASIC keeps the combinational constants
    // (inherently SEU-immune, the whole reason firmware lives in ROM).
    reg [31:0] i_rdt_r, rdt_r;
    reg        ack_r;
    always @(posedge clk) begin
        i_rdt_r <= mem[i_adr_i[9:2]];
        rdt_r   <= mem[adr_i[9:2]];
        ack_r   <= cyc_i & ~ack_r;
    end
    assign i_rdt_o = i_rdt_r;
    assign rdt_o   = rdt_r;
    assign ack_o   = ack_r;
`else
    // ASIC: register ONLY the instruction fetch port. This is a routing
    // fix, measured: the scrubbed mask's constants reshaped the flat
    // 256x32 combinational fetch mux into a congestion pocket global
    // routing could not clear (four six-hour runs plateaued at ~5k
    // shorts). Pipelining just that mux dissolves the cone. Timing-safe -
    // the SoC's ibus_ack is already one cycle delayed, so the registered
    // fetch lands exactly on the ack cycle SERV samples (proven: full
    // boot / command path / checksum in simulation). The dbus port stays
    // combinational so the 'R' checksum read is byte-identical - and it
    // is registering the DBUS read that broke the command path, which is
    // why only the fetch mux is pipelined. The 32 fetch flops are
    // ordinary pipeline registers; the ROM contents stay synthesized
    // constants (the SEU immunity is about where bits live).
    reg [31:0] i_rdt_a;
    always @(posedge clk) i_rdt_a <= mem[i_adr_i[9:2]];
    assign i_rdt_o = i_rdt_a;
    assign rdt_o   = mem[adr_i[9:2]];
    assign ack_o   = cyc_i;
`endif

endmodule

`default_nettype wire
