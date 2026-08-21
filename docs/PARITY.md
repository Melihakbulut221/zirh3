# ZIRH-3 vs VORAGO VA10805 - the technical parity ledger

The VA10805 is the program's chosen yardstick: a radiation-hardened
Arm Cortex-M0 microcontroller (HARDSIL process hardening, up to
50 MHz, core 1.5 V, I/O 3.3 V - per VORAGO's public product page and
the VA108x0 family datasheet). This ledger records where ZIRH-3's
compute cluster stands against it, feature by feature, and pins the
MEASURED physics of the protection - numbers from this repository's
own campaign runs, not estimates from slideware.

Scope honesty up front: ZIRH-3's numbers describe the compute
CLUSTER (zirh_vex_wrap: pipelined RV32IM core + icache on RM
macros), tool-reported at the typical corner from the routed layout.
The VA10805 numbers describe a finished, qualified MCU product.
Feature parity is claimed where proven; physics comparisons are
stated only where the conditions are like for like.

## Feature parity (all proven in this repository)

| axis | VA10805 | ZIRH-3 | status |
|---|---|---|---|
| CPU class | Cortex-M0 (Thumb, 3-stage) | VexRiscv RV32IM (pipelined, cached) | IPC parity measured in the Cycle 14 campaign; RV32IM carries hardware multiply/divide |
| clock | up to 50 MHz | 50 MHz closed through P&R, every corner, routed + extracted | Cycles 15-18 (plain), Cycle 20 (stitched) |
| protection | HARDSIL process hardening | tool-stitched voted-feedback TMR, every flop (2138 triples) | different philosophies: process vs architecture; ZIRH-3's is proven by wound (Cycle 19) and survives P&R (Cycles 20-21) |
| data memory | 32 KB SRAM | 256 KB bank, 5-slice SECDED + scrubber + address-in-ECC | Cycle 17; SECDED proven formally and by the lying-memory scenario |
| program execution | flash/ROM + SRAM | loaded programs run FROM the protected bank | Cycle 17 fetch proof |
| debug | SWD | IEEE 1149.1 TAP + RISC-V DTM/DM behind the flight lock | F27 |
| GPIO | 56 pins, PORTA 32 + PORTB 24 | 56 pins, same split, at bus slot 6 - OUT/DIR TMR'd, IN double-synced, err into the die aggregate | Cycle 27; block + through-the-die suites |
| timers | 24x 32-bit, capture/compare/PWM/pulse, pinned via GPIO alt functions | 24x 32-bit at slot 7, same four modes, PORTB alternate functions, EVERY register TMR'd including the running counters, timer 0 irq wired to the core | Cycle 30; feature subset honest: no cascade/chaining |
| I2C | 2 controllers | 2 masters at slot 6's upper half (0x6800/0x6C00), byte-command engine, open-drain on PORTA[3:0] alternate functions, clock-stretch OBEYED, all state TMR'd | Cycle 31; subset honest: master only, no slave mode |
| SPI | 3 (2 master/slave + 1 master), 4-16 bit words, 16-word FIFOs, multiple chip selects | 3 masters at slot 7's upper half, all four modes, full duplex, 4-16 bit words (WLEN), 16-deep TMR'd FIFOs both directions with OE, four decoded selects per master (CSSEL/MCS, extra lines on PORTA[26:18]), software-owned CS, all state TMR'd | Cycles 32+36; subset honest: master only, no slave mode |
| UART | 2 | 2 - the shared lifeline (console + telemetry + ISP, dedicated pins, strapped rate) plus the payload's programmable port at 0x7B00 on PORTA[17:16]: 16-deep TMR'd FIFOs both directions, parity (even/odd, enforced on receive), second stop bit, sticky OE/FERR/PERR flags, all state TMR'd | Cycles 33+35; the ledger's last column, now at the yardstick's depth |
| interrupts | per-peripheral IRQs via selector into the NVIC, per-pin GPIO interrupts | 32-source fabric at 0x6400 - 24 timer overflows, UART1 rx/tx, 2 I2C + 3 SPI ready - TMR'd mask, RAW/PENDING readable, masked lines into the core's external interrupt array; timer 0 also on the dedicated timer line | Cycle 34; subset honest: no per-pin GPIO interrupt sources yet |
| DFT | (production test, undisclosed) | MBIST from software, boundary scan, scan-insertion flow | F28 |

## Measured physics of the protection (the price tag)

Same flow, same PDK (IHP SG13G2 130 nm open), same 45 percent
placement density target, typical corner (1.20 V, 25 C), activity
defaults; flow-reported metrics from the runs named below.

| metric | unstitched cluster (run 31976805625) | stitched cluster (run 32271803469) | ratio |
|---|---|---|---|
| stdcell area (routed, with clock tree) | 246,838 um2 | 601,842 um2 | 2.44x |
| die area | 620,000 um2 (1000x620) | 1,305,000 um2 (1450x900) | 2.10x |
| sequential cells | 2,138 | 6,414 | 3.00x |
| total power (tool estimate, typ) | 8.02 mW | 24.41 mW | 3.04x |
| power breakdown | 6.78 int / 1.24 sw / 0.007 lk | 20.72 int / 3.66 sw / 0.029 lk | - |
| worst IR drop | - | 3.54 mV (grid violation count 0) | - |
| timing at 50 MHz | +5.44 ns setup slow, hold ECO'd + confirmed | hold +0.19 / setup +2.58 every corner, confirmed | both closed |

Readings, plainly: architecture-level TMR costs 2.4x cell area and
3x power on this cluster at unchanged frequency - that is the price
of carrying the protection in logic the fab does not have to know
about. HARDSIL pays its (undisclosed) price in process instead. The
program's position is unchanged: ZIRH-3's protection is inspectable,
provable by wound-and-heal in simulation, and portable to any
foundry; those properties were bought with the area and power above,
and the ledger says exactly how much.

## What this ledger does NOT claim

- No power comparison against the VA10805 is made here. Our 24.4 mW
  is a tool estimate for a bare digital cluster at 1.2 V core on
  130 nm; a datasheet run-current for a finished MCU (regulators,
  I/O, flash, peripherals) at 1.5 V core is a different measurement
  of a different thing. A like-for-like number is bench work behind
  the B10 gate, with the datasheet's DC tables on the table.
- No radiation comparison. HARDSIL has flight heritage and qualified
  SEL/TID numbers; ZIRH-3's equivalents are exactly what the ZIRH-1/2
  beam campaign (B10) exists to produce.
- No product comparison. The VA10805 ships; ZIRH-3 is a rehearsal
  that waits, deliberately, on data.
