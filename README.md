# ZIRH-3

[![ci](https://github.com/Melihakbulut221/zirh3/actions/workflows/ci.yaml/badge.svg)](https://github.com/Melihakbulut221/zirh3/actions/workflows/ci.yaml)
[![pnr](https://github.com/Melihakbulut221/zirh3/actions/workflows/pnr.yaml/badge.svg)](https://github.com/Melihakbulut221/zirh3/actions/workflows/pnr.yaml)

One badge, four judges: the ci workflow carries checks (lint,
traceability, TMR guard, DFT and stitcher pilots, the equivalence
pilot), units (every block and top suite plus both storms), gl (the
gate ladders, the full-die boot, the core equivalence) and formal
(the SMT theorems) as parallel jobs on every push. The pnr badge is
the dispatchable campaign workflow - P&R closure, signoff, the
layout equivalence - green at its latest dispatched run.

The dedicated-die rehearsal of the ZIRH program: the radiation-
tolerant SoC whose every block was designed, verified and argued for
inside [zirh2](https://github.com/Melihakbulut221/zirh2), integrated
here into the chip those blocks were always aimed at - and GATED by
the program's own rule: silicon is committed when ZIRH-1/2 beam data
closes the open decision gates, not when the backlog feels ready.

ZIRH-2 is the experiment: a TT-harness instrument that measures the
price of placement separation. ZIRH-3 is the product rehearsal: its
own padframe, POR, controlled well-tap and guard-ring density, real
SRAM macros, a boot path from external MRAM, a lockable debug port -
on the free IHP OpenMPW ~2 mm2 open-source slot, so the rehearsal
waits behind the DATA gate, not a money gate.

## Block diagram

![ZIRH-3 as built](docs/fig/block_diagram.svg)

## What lives here now

The verified block library, imported at its proven state and kept
green by the same discipline (every suite in CI, synthesis-integrity
checked, formal proofs run on every push):

| block | role | proof |
|---|---|---|
| zirh_sram39 | the sliced 39-bit SECDED array with a background scrubber - and since Cycle 41 a VOTED transaction path: state, captured row, read register and ack flop in TMR with mismatches in err_o, because an upset in the wrapper handed the CPU a stale word with a valid ack while the array itself was perfectly protected | test_sram39, f_amask, f_ecc |
| zirh_sram_bist | march/pattern engine for the macro word | test_bist |
| zirh_boot_ctrl | trusted loader: MAGIC/len/ver/CRC32 image, READ-BACK verify of the stored words, A/B banks, watchdog revert ladder, ISP | test_boot, SV scenario suite incl. the lying-memory case |
| zirh_qspi | QSPI-MRAM controller, x1/x4, backpressure = SCK freeze | test_qspi |
| zirh_dbg_gate | debug isolation: flight lock latched at POR, TMR trap to LOCKED | test_dbg_gate, f_dbg |
| zirh_clkobs | clock-loss observer on an independent RO clock | test_clkobs |
| zirh_tmr_lib | voted-feedback TMR primitives, the escape-window theorem carrier | f_ring (BMC + k-induction) |
| zirh_mbist | MBIST doorway at slot 5: march control, raw fail record, and the TMR page register that maps 256 KB through the 4 KB window | test_top_isp (ISP-loaded runner) |
| zirh_vex_wrap | the compute upgrade: VexRiscv_Lite (RV32IM, vendored) on the soc's native Wishbone; 50 MHz closed through full P&R with cache arrays on RM 2P macros, hold ECO'd and CONFIRMED - the exact layout routed, extracted and closed at every corner | pnr campaign record, tb_vex |
| zirh_bank64 | 256 KB paged bank on 4096-deep macros: 16 sliced-SECDED pages, program store (the core fetches from it) plus A/B data, CPU windowed, SBA and loader flat | test_top_isp paging + fetch proofs |
| boundary scan | SAMPLE/PRELOAD + EXTEST on the TAP, 12 cells over the functional pins, drive masked by the flight lock | tb_bscan |
| scan flow | post-synthesis scan insertion proven on a pilot block: real SG13G2 scan cells, stitched chain, shift + capture | scripts/dft_scan.sh |
| GL boot proof | the TMR-stitched gate netlist of the compute cluster (2173 flops, every one voted) boots the full ISP story inside the RTL top; a whole replica rail forced wrong is masked and heals on release; the majority-wound control falls silent | scripts/gl_boot.sh, test_top_gl |
| stitched P&R | the same stitched netlist closes 50 MHz through full place-and-route (synthesis disabled so the optimizer cannot collapse the triples): hold +0.20 / setup +1.29 at every corner, routed and extracted (the Cycle 46 refresh of the original +0.19/+2.58 seal); 2173 rail-net triples counted by name in the confirmed DEF; protection price 2.49x cell area | pnr/vextmr campaign record |
| layout boot proof | the CONFIRMED database's own netlist - clock tree, repair buffers, tie cells - boots the ISP story and survives the wound trio; what was handed to the flow, what the flow closed, and what it handed back are one proven thing | pnr/vextmr/dump_netlist.tcl, scripts/gl_pnr_boot.sh |
| signoff pre-work | the two GDS streamouts merge the macro GDS to identical geometry (XOR zero across 38 layers) and LVS matches every device exactly, with the only mismatches pinned to two root-caused tool-view classes - a new class fails the gate | scripts/xor_streams.py, scripts/signoff_lvs.sh |
| SEU rain | random single-replica upsets - one clock each, verified to land and to heal - fall while the boot story runs: 314 shots over three storms, zero divergence, the flood alive at the end; a storm too thin to prove anything fails its own gate | test_top_seu, gl ladder stage 7 |
| full-die GL boot | the WHOLE die - loader, bank, telemetry, watchdog, debug gate, POR - boots as SG13G2 gates with the stitched CPU in its socket; the wound trio and the rain hold on the full gate die, benches unchanged | scripts/gl_die.sh, make gldie |
| zirh_gpio | 56 GPIO at VORAGO parity (PORTA 32 + PORTB 24, slot 6): TMR'd OUT/DIR - a flipped direction bit is a fighting driver - synced IN, and an ISP-loaded program proven to own both directions of the pin boundary | test_gpio, test_top_gpio |
| formal equivalence | every hop is a theorem: RTL-to-stitched proven at pilot scale, the stitch at 2173 triples (2674/2674 points), and place-and-route itself - the confirmed layout's netlist vs what entered the flow, 7020/7020 points with the clock tree and repair buffers collapsing inside the proof; cell functions generated from the PDK liberty, vacuous passes refused by gate | scripts/formal_equiv.sh, make equiv |
| zirh_timer | 24x 32-bit timers at VORAGO parity (slot 7): timer/PWM/capture/pulse modes, PORTB alternate functions (a leased pin is a timer's pin), every register TMR'd - a flipped counter bit is a wrong period, a flipped compare a wrong duty forever - and timer 0's overflow is the core's timer interrupt, wired at last | test_timer, test_top_timer |
| zirh_i2c | the I2C pair (slot 6 upper half): a byte-command master that OBEYS clock stretch but is no longer HOSTAGE to it - past a parameterized limit the leg is abandoned with a sticky W1C verdict and the wire released - plus a slave chair at the same pins with 16-deep queues, NACK-at-full backpressure and repeated START; disabled or parked, the engine is idle rather than frozen | test_i2c, test_top_i2c |
| the boot contract | [docs/BOOT.md](docs/BOOT.md): the wire format, the valid/ready clause and where it bites, the one-ruling-per-reset ruling, the revert ladder, and the fault model that judges the STORED image rather than the stream - derived from the code, with its honest limits named | cited by zirh_boot_ctrl, zirh_qspi |
| formal proofs | five harnesses: TMR escape window, SECDED contract, address mask, debug-lock trapdoor and the boot controller's rulings - plus a self-test that refuses to report any theorem on a toolchain that silently drops assertions | make formal |
| autonomous boot | PORTA 31 strapped high: the die streams its own image from external MRAM over a four-wire x1 QSPI lease (PORTA 30-27, five pins with the source strap on 31) through the SAME loader contract - not one UART byte; pin low, the ground flow is bit-identical | test_top_qspi |
| zirh_spi | the SPI master trio (slot 7 upper half): all four modes, 4-16 bit words left-justified at launch, 16-deep queues both directions - a burst drains under one held select, a reply meeting a full queue drops and flags OE - four decoded chip selects steered by CSSEL under MCS, software owns WHEN every select is low, all state TMR'd | test_spi, test_top_spi |
| zirh_fifo | the TMR'd queue primitive: sixteen entries and both pointers all in voted registers, refusal at both walls, an exact level gauge - the depth every serial port borrows | test_fifo |
| zirh_uart1 | the payload's serial port (slot 7 window 3): programmable frames with parity and a second stop, exact-div bit periods, 16-deep queues both directions - overflow drops the newcomer and flags OE so the oldest data survives, a lying parity or broken stop flags PERR/FERR and never queues - all state TMR'd; proven echoing bench bytes across two UARTs at two rates | test_fifo, test_uart1, test_top_uart1 |
| zirh_irq | the interrupt fabric (slot 6, 0x6400): 32 level sources - 24 gated timer overflows, UART1 rx/tx, I2C and SPI ready - behind one TMR'd mask, PENDING = RAW AND MASK and nothing latched, the masked word driving the core's external interrupt array; the integration also connected the core's timer interrupt, tied off since the bank arrived | test_irq, test_top_irq |
| the storms | seeded uncurated fuzz at two boundaries - the loader at its ports (120 episodes per seed, continuous invariants, liveness cadence) and the die at its pins (armed/closed coverage bins) - with closure gates that fail a thin storm; the first drafts surfaced the loader's unstated one-ruling-per-reset contract, now locked in oracles | zirh_boot_fuzz_tb, test_top_fuzz, make fuzz |

The integration map, the honest new-design list (pad ring, ESD, POR,
the RO clock source, physical macro hardening) and the scope
discipline are in [docs/SCOPE.md](docs/SCOPE.md). The measured
parity ledger against the VORAGO VA10805 - features proven, the
protection's area and power price tags from the campaign's own
layouts, and the comparisons deliberately not made - is
[docs/PARITY.md](docs/PARITY.md). The program
register mapping the commercial brief onto THIS repository is
[docs/PROGRAM.md](docs/PROGRAM.md).

## Running the proofs

    make units      # all six block suites (cocotb + iverilog)
    make sv         # the SV scenario suite (boot stories, storage_lie)
    make formal     # yosys-smtbmc + z3: ring theorem, SECDED, amask, dbg
    make tmr        # synthesis-integrity: replicas survive the optimizer
    make lint       # verilator, warning-clean policy

## Provenance

Every block arrives with its verification history in the zirh2
repository - cycle-by-cycle design notes, the bugs found and the
probes that found them. This repository starts where that one's
product program ended; nothing here is unproven code.

Apache-2.0, like everything in the program.

---

*ZIRH-2 measures. ZIRH-3 is what the measurements are for.*
