// =============================================================================
// ZIRH-2 - SoC core cluster: SERV + ROM + bus + ECC RAM + UART registers
// zirh_soc.v
//
// The computing element of ZIRH-2, without pins or the ZIRH-2 top (those
// come with the SEU monitor v2 and the pin map). SERV 1.3.0 is vendored
// unmodified in src/serv/ (pin: see src/serv/VERSION).
//
// Integration decisions:
//   * WITH_CSR=0: the housekeeping loop needs no traps or interrupts, and
//     dropping the CSR file removes 4x32 bits of unprotected CPU state.
//   * Instruction fetch is point to point to the ROM, not through the bus:
//     on a single-master interconnect ifetch would serialize against data
//     traffic for no benefit, and constants have no port conflicts.
//   * Both SERV bus interfaces get REGISTERED acks (one wait state). Our
//     slaves ack combinationally, which Wishbone permits, but SERV's state
//     machine is normally deployed behind registered-ack memories
//     (servant); a clean one-cycle handshake costs one cycle per access
//     and removes the protocol risk entirely. The dbus read data is
//     latched with the ack so the CPU never samples a mux that has
//     already moved on - the bus watchdog's DEADBEEF response lasts a
//     single cycle, and without the latch it would be lost.
//   * SERV's internal state (including the 32x32 register file) is PLAIN.
//     That is the honest v1 hardening story: this CPU is itself a beam
//     target, its crash rate is a measurement, and the firmware's rolling
//     signature makes crashes visible from the ground. Hardening the core
//     comes after silicon area is measured, not before.
//
// Memory map (bus slot = adr[14:12]):
//   slot 0  0x0000  ROM (also on dbus, for boot-time image checksums)
//   slot 1  0x1000  ECC RAM, 64 B
//   slot 2  0x2000  UART registers
//   slot 3  0x3000  housekeeping (exported)
//   slot 4  0x4000  sliced SECDED bank (exported)
//   slot 5  0x5000  MBIST doorway (exported)
// =============================================================================

`default_nettype none

module zirh_soc #(
    parameter ROM_HEX   = "",
    parameter RESET_DIV = 174
) (
    input  wire       clk,
    input  wire       rst_n,

    // POR-domain reset for the ECC RAM only: the loaded bank must
    // survive both the ISP hold and watchdog reboots (the loader and
    // its bank live across everything short of a power cycle)
    input  wire       por_rst_n_i,

    // ISP loader port (top-level zirh_boot_ctrl, POR domain). While
    // isp_hold_i the loader owns the ECC RAM and the rest of the SoC
    // is held in reset by the top; with boot_sel_i the CPU fetches
    // from the loaded bank instead of the mask ROM.
    input  wire        isp_hold_i,
    input  wire        boot_sel_i,
    input  wire        isp_cyc_i,
    input  wire [31:0] isp_adr_i,
    input  wire [31:0] isp_dat_i,
    input  wire        isp_we_i,
    output wire [31:0] isp_rdt_o,
    output wire        isp_ack_o,

    // UART pins
    output wire       uart_tx_o,
    input  wire       uart_rx_i,

    // telemetry byte stream into the TX arbiter (from zirh_tlm, later)
    input  wire [7:0] tlm_data_i,
    input  wire       tlm_valid_i,
    output wire       tlm_ready_o,

    // slot 3 slave interface, exported for the housekeeping block
    output wire        s3_cyc_o,
    output wire [31:0] s3_adr_o,
    output wire [31:0] s3_dat_o,
    output wire        s3_we_o,
    input  wire [31:0] s3_rdt_i,
    input  wire        s3_ack_i,

    // slot 4 slave interface, exported for the sliced SECDED bank
    // (zirh_sram39 lives at the top: its macros, scrubber and BIST are
    // die-level property, the soc only speaks bus to it) - ZIRH-3
    output wire        s4_cyc_o,
    output wire [3:0]  s4_sel_o,
    input  wire [31:0] s4_rdt_i,
    input  wire        s4_ack_i,

    // slot 5 slave interface, exported for the MBIST doorway (adr/dat/we
    // ride the shared s3 export lines, like slot 4) - ZIRH-3 F28
    output wire        s5_cyc_o,
    input  wire [31:0] s5_rdt_i,
    input  wire        s5_ack_i,

    // observability
    output wire       evt_bus_timeout_o,
    output wire       evt_ecc_corr_o,
    output wire       evt_ecc_uncorr_o,
    output wire       rx_ferr_o,
    output wire       err_o              // TMR mismatches (bus wd, uart, baud)
);

    // --- the core (Cycle 14: VexRiscv_Lite, RV32IM, pipelined) --------------
    // The wrapper's interface mirrors the SERV wrapper's exactly, so
    // this section changed one instantiation and one assumption: a
    // PIPELINED core issues instruction and data traffic in the same
    // cycle, which the bit-serial core never did - the fetch-side ack
    // below now yields to a data-bus collision instead of assuming one
    // cannot happen.
    wire [31:0] ibus_adr, ibus_rdt, dbus_adr, dbus_dat, dbus_rdt;
    wire [3:0]  dbus_sel;
    wire        ibus_cyc, dbus_cyc, dbus_we;

    reg         ibus_ack, dbus_ack;
    reg  [31:0] dbus_rdt_q;

    zirh_vex_wrap u_cpu (
        .clk           (clk),
        .rst_n         (rst_n),
        .timer_irq_i   (1'b0),
        .reset_vector_i(32'h0000_0000),
        .ibus_adr_o    (ibus_adr),
        .ibus_cyc_o    (ibus_cyc),
        .ibus_rdt_i    (ibus_rdt),
        .ibus_ack_i    (ibus_ack),
        .dbus_adr_o    (dbus_adr),
        .dbus_dat_o    (dbus_dat),
        .dbus_sel_o    (dbus_sel),
        .dbus_we_o     (dbus_we),
        .dbus_cyc_o    (dbus_cyc),
        .dbus_rdt_i    (dbus_rdt_q),
        .dbus_ack_i    (dbus_ack)
    );

    // --- ROM: ibus point to point, dbus as slot 0 ---------------------------
    wire [31:0] rom_dbus_rdt;
    wire        rom_dbus_ack;
    wire        rom_dbus_cyc;

    wire [31:0] rom_i_rdt;

    zirh_rom #(.HEX(ROM_HEX)) u_rom (
        .clk     (clk),
        .i_adr_i (ibus_adr),
        .i_rdt_o (rom_i_rdt),
        .cyc_i   (rom_dbus_cyc),
        .adr_i   (dbus_adr),
        .rdt_o   (rom_dbus_rdt),
        .ack_o   (rom_dbus_ack)
    );

    // Fetch source select: the mask ROM always, or the loaded bank when
    // the ISP controller has committed an image. Bank fetches go through
    // the ECC RAM's corrected read port, so a fetched word is scrubbed
    // and counted exactly like a data read.
    wire [31:0] ram_rdt;
    wire        ram_ack;

    wire fetch_ram = boot_sel_i & ibus_cyc & ~s_cyc[1] & ~ibus_ack;

    // both fetch sources answer combinationally (ROM decode, RAM
    // corrected read), so the registered one-wait ibus ack works for
    // either - but in bank mode the RAM port is SHARED with the data
    // bus, and a pipelined core can drive both buses in one cycle.
    // The data side owns the port (s_cyc[1] wins the mux below), so
    // the fetch ack must yield during the collision or the fetch
    // would silently ack the DATA access's read word as an
    // instruction.
    wire fetch_stall = boot_sel_i & s_cyc[1];

    assign ibus_rdt = boot_sel_i ? ram_rdt : rom_i_rdt;

    always @(posedge clk) begin
        if (!rst_n) ibus_ack <= 1'b0;
        else        ibus_ack <= ibus_cyc & ~ibus_ack & ~fetch_stall;
    end

    // The CPU cannot issue data traffic before it has executed an
    // instruction, so gating the bus until the first fetch completes is a
    // behavioral no-op in silicon - and it stops SERV's MINI-reset X from
    // reaching the bus, the ECC event registers and the watchdog during
    // the first boot cycles (in 4-state simulation that X would poison
    // the housekeeping TMR counters permanently; measured).
    reg cpu_awake;
    always @(posedge clk) begin
        if (!rst_n)        cpu_awake <= 1'b0;
        else if (ibus_ack) cpu_awake <= 1'b1;
    end

    // --- bus + slaves -------------------------------------------------------
    wire [31:0] m_rdt;
    wire        m_ack;
    wire [7:0]  s_cyc;
    wire [31:0] s_adr, s_dat;
    wire [3:0]  s_sel;
    wire        s_we;
    wire [255:0] s_rdt;
    wire [7:0]   s_ack;
    wire         err_bus;

    zirh_bus u_bus (
        .clk           (clk),
        .rst_n         (rst_n),
        .m_adr_i       (dbus_adr),
        .m_dat_i       (dbus_dat),
        .m_sel_i       (dbus_sel),
        .m_we_i        (dbus_we),
        .m_cyc_i       (cpu_awake & dbus_cyc & ~dbus_ack),
        .m_rdt_o       (m_rdt),
        .m_ack_o       (m_ack),
        .s_cyc_o       (s_cyc),
        .s_adr_o       (s_adr),
        .s_dat_o       (s_dat),
        .s_sel_o       (s_sel),
        .s_we_o        (s_we),
        .s_rdt_i       (s_rdt),
        .s_ack_i       (s_ack),
        .evt_timeout_o (evt_bus_timeout_o),
        .err_o         (err_bus)
    );

    // registered ack + latched read data toward SERV
    always @(posedge clk) begin
        if (!rst_n) begin
            dbus_ack   <= 1'b0;
            dbus_rdt_q <= 32'h0;
        end else begin
            dbus_ack <= dbus_cyc & m_ack & ~dbus_ack;
            if (dbus_cyc & m_ack & ~dbus_ack)
                dbus_rdt_q <= m_rdt;
        end
    end

    // slot 0: ROM on the data bus
    assign rom_dbus_cyc = s_cyc[0];
    assign s_rdt[31:0]  = rom_dbus_rdt;
    assign s_ack[0]     = rom_dbus_ack;

    // slot 1: ECC RAM - three masters, one port, no overlap by
    // construction: the ISP loader owns it while the CPU is held;
    // afterwards the CPU's dbus and (when running from the bank) its
    // fetch path share it, and SERV never has both in flight at once.
    // The RAM lives on the POR reset so the loaded image survives both
    // the ISP hold and watchdog reboots.
    wire evt_corr, evt_uncorr;

    wire        ram_cyc = isp_hold_i ? isp_cyc_i
                                     : (s_cyc[1] | fetch_ram);
    wire [31:0] ram_adr = isp_hold_i ? isp_adr_i
                                     : (s_cyc[1] ? s_adr : ibus_adr);
    wire [31:0] ram_dat = isp_hold_i ? isp_dat_i : s_dat;
    wire [3:0]  ram_sel = (isp_hold_i | ~s_cyc[1]) ? 4'hF : s_sel;
    wire        ram_we  = isp_hold_i ? isp_we_i : (s_cyc[1] & s_we);

    // ZIRH-3 storage rung: 128 words - bank A and bank B at 64 words
    // each, four times the ZIRH-2 loaded-program space
    zirh_ecc_ram #(.WORDS(128)) u_ram (
        .clk          (clk),
        .rst_n        (por_rst_n_i),
        .cyc_i        (ram_cyc),
        .adr_i        (ram_adr),
        .dat_i        (ram_dat),
        .sel_i        (ram_sel),
        .we_i         (ram_we),
        .rdt_o        (ram_rdt),
        .ack_o        (ram_ack),
        .evt_corr_o   (evt_corr),
        .evt_uncorr_o (evt_uncorr)
    );
    assign s_rdt[63:32] = ram_rdt;
    assign s_ack[1]     = ram_ack & s_cyc[1] & ~isp_hold_i;
    assign isp_rdt_o    = ram_rdt;
    assign isp_ack_o    = ram_ack & isp_hold_i;
    assign evt_ecc_corr_o   = evt_corr;
    assign evt_ecc_uncorr_o = evt_uncorr;

    // slot 2: UART registers
    wire err_uart;
    zirh_uart_regs #(.RESET_DIV(RESET_DIV)) u_uart (
        .clk         (clk),
        .rst_n       (rst_n),
        .cyc_i       (s_cyc[2]),
        .adr_i       (s_adr),
        .dat_i       (s_dat),
        .we_i        (s_we),
        .rdt_o       (s_rdt[95:64]),
        .ack_o       (s_ack[2]),
        .tlm_data_i  (tlm_data_i),
        .tlm_valid_i (tlm_valid_i),
        .tlm_ready_o (tlm_ready_o),
        .uart_tx_o   (uart_tx_o),
        .uart_rx_i   (uart_rx_i),
        .rx_ferr_o   (rx_ferr_o),
        .err_o       (err_uart)
    );

    // slot 3: exported to the top (zirh_hk lives there, outside the soc,
    // because its counters feed the telemetry framer directly)
    assign s3_cyc_o       = s_cyc[3];
    assign s3_adr_o       = s_adr;
    assign s3_dat_o       = s_dat;
    assign s3_we_o        = s_we;
    assign s_rdt[127:96]  = s3_rdt_i;
    assign s_ack[3]       = s3_ack_i;

    // slot 4: exported to the top for the sliced SECDED bank (0x4000);
    // adr/dat/we ride the shared s3 export lines - one master, the
    // per-slot cyc is the select
    assign s4_cyc_o       = s_cyc[4];
    assign s4_sel_o       = s_sel;
    assign s_rdt[159:128] = s4_rdt_i;
    assign s_ack[4]       = s4_ack_i;

    // slot 5: exported to the top for the MBIST doorway (0x5000); same
    // shared-lines pattern as slot 4
    assign s5_cyc_o       = s_cyc[5];
    assign s_rdt[191:160] = s5_rdt_i;
    assign s_ack[5]       = s5_ack_i;

    // slots 6..7: unpopulated - the bus watchdog owns them
    assign s_rdt[255:192] = 64'h0;
    assign s_ack[7:6]     = 2'b0;

    assign err_o = err_bus | err_uart;

endmodule

`default_nettype wire
