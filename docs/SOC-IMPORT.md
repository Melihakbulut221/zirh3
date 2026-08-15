# SoC cluster import plan (PROGRAM.md execution order, step 5)

The remaining major integration: bring the SERV-based computing cluster
into ZIRH-3 and attach it to the memory subsystem this repository has
already stood up. Scoped as ASSEMBLY, not invention - every piece is
proven in zirh2; this document is the parts list and the wiring so the
import is a bounded, verifiable step rather than an open-ended one.

## What comes over (all proven in zirh2)

- src/serv/*.v (17 files): SERV 1.3.0, vendored unmodified. Pin lives
  in src/serv/VERSION; it carries the escape-window methodology.
- zirh_rom.v + rom_init.vh: the mask ROM and its committed firmware
  image (the golden copy the loader falls back to).
- zirh_bus.v: the single-master interconnect with the bus watchdog.
- zirh_uart_regs.v + zirh_rs422.v: the command/telemetry UART path.
- zirh_soc.v: the cluster top - ALREADY carries the ISP fetch mux
  built for ZIRH-2 (por_rst_n_i, isp_hold_i, boot_sel_i, the
  isp_cyc/adr/dat/rdt/ack port that muxes CPU fetch between the mask
  ROM and the ECC-protected bank). This is the exact attachment point
  to this repo's loader and bank.

## The attachment (the mux is already proven)

zirh_soc.v exposes the ISP loader port. In ZIRH-2 that port drove the
64 B ECC RAM; here it drives zirh3_memsys's sram39 bank. The wiring:

  zirh3_die
    +-- zirh_por_ro          -> sys_rst_n, ro_clk, ro_rst_n   (Cycle 3)
    +-- zirh_soc             -> CPU + ROM + bus + UART
    |     isp_hold_i/boot_sel_i/isp_* <---> u_boot (the loader)
    |     the sram39 bank is the soc's data+fetch memory
    +-- zirh3_memsys blocks   -> loader, bank, qspi, clkobs, dbg
                                 (Cycle 2), now driven by the soc

The key change from Cycle 2's memsys: the sram39 bank's functional
port (men/wen/ren/adr/d/q), tied off in the skeleton, connects to the
soc's data bus; boot_sel_o hands fetch between ROM and bank exactly as
zirh2 proved. No new datapath - the mux exists and is tested.

## Firmware

rom_init.vh comes over as the golden image. A ZIRH-3-specific
firmware (its own memory map for the dedicated die's peripherals) is a
later step; the imported image boots the cluster and proves the
methodology carries, which is C12's stated purpose.

## Verification ladder (each gates the next)

1. SERV + soc ELABORATE and lint clean in this tree (the first
   concrete import step - CPU cluster present and warning-clean).
2. The zirh2 SoC cocotb suite retargets: boot, echo, the command set,
   the living-CPU frame - proving the imported cluster runs.
3. Integration: soc attached to the memsys bank via the ISP mux; the
   die boots ROM firmware, and an ISP image loads into the sram39 bank
   and runs (the ZIRH-2 test_isp contract, retargeted to the real
   sliced bank instead of the 64 B ECC RAM - a stronger demonstration).
4. Synthesis integrity on the full die; the placement recipe and its
   campaign discipline carry from zirh2 for the hardening trials.

## Why this is deferred to its own focused step

The import touches ~22 files and needs firmware, and the payoff is a
full-die integration best done unhurried with each ladder rung
verified. This plan makes it assembly: the parts are proven, the
attachment point (the ISP mux) is tested, and the ladder is written.
The gate that governs it all still holds - B10, silicon waits for
beam data; this import grows the design, not the silicon commitment.

## Status: the ladder is complete

Every rung above is climbed and green (Cycles 5-12): the cluster
elaborates and lints clean, its suite runs retargeted, the loader
programs the sliced bank through the proven ISP mux and loaded code
RUNS, the bank serves as CPU data memory, the debugger's SBA reaches
it through the flight lock, and the housekeeping/telemetry cluster
with the watchdog-revert signon completes the boot contract. Cycle 13
added what the ladder deferred: the DFT layer (MBIST doorway,
boundary scan, the scan-insertion flow). Synthesis integrity is
re-measured at every step - 70 replicas / 4219 flops on the full die.
The gate holds: B10, silicon waits for beam data.
