# ZIRH-3 scope: the dedicated die, gated by data

The program has, in simulation, built every piece a dedicated
radiation-tolerant SoC needs: SECDED SRAM with slicing, scrubber and
address protection; a QSPI-MRAM boot path; a debug isolation gate; a
BIST engine; a clock-loss observer. ZIRH-3 is where they become one
die. This document is its scope - and, as importantly, its GATE: the
program's own measure-before-believing rule applies to ZIRH-3 itself.

## The gate comes first (B10, obstacle 14)

ZIRH-3 does NOT start because the blocks are ready. It starts when
ZIRH-1 and ZIRH-2 silicon has produced beam data that closes the open
decision gates - because a dedicated die that bakes in an unverified
placement-A/B assumption would be the one time this program believed
before it measured. The blocks below are DESIGN-READY, not
tape-out-authorized. Building them in simulation now is correct;
committing them to silicon waits for the gate. This document exists
so that when the gate opens, integration is assembly, not invention.

## Vehicle (from docs/MPW-COST.md)

The free IHP OpenMPW ~2 mm2 open-source slot is the ZIRH-3 vehicle:
a real dedicated die - own padframe, own POR, controlled guard-ring
and well-tap density - at zero fabrication cost, on exactly this
repository's open flow and license. The dedicated-design rehearsal
therefore waits behind THIS data gate, not behind money.

## Integration map (all blocks exist in src/ today)

```
  pad ring + ESD + POR/brown-out        [NEW: product-chip essentials,
       |                                 obstacle 2 - the one genuinely
       v                                 new design area]
  clk_rst + zirh_clkobs  <-- RO clock   [clock-loss observer, Cycle 23]
       |
  SERV (or the C12 core when it lands)   [SERV first: the methodology
       |  ibus/dbus                       carries; core swap is later]
  +----+--------------------------------+
  |  zirh_boot_ctrl  <-- zirh_qspi <-- MRAM (on-board discrete)
  |       | commits into                 [A5 boot path, Cycles 22/13]
  |  zirh_sram39 (sliced SECDED + scrubber + BIST)
  |       |                              [Cycles 11/12/15]
  |  zirh_dbg_gate  <-- riscv-dbg (F27)   [debug isolation, Cycle 14]
  +-------------------------------------+
  housekeeping + env (radiation canary) + interfaces + telemetry
       |                                 [all shipping on ZIRH-2]
  the placement-A/B experiment, carried forward for the DEDICATED
  layout where guard rings and separation are OURS to control
```

## What is genuinely new (the honest new-design list)

Everything above except three items is proven in simulation on
ZIRH-2 or built and unit-tested this program. The genuinely new
silicon design, the part that needs the most review, is small and
named:

1. **Pad ring, ESD, POR/brown-out** - obstacle 2's essentials, the
   TT harness provided these and a dedicated die must not.
2. **The RO clock source for the observer** - zirh_clkobs takes an
   independent clock as input; on a dedicated die that clock is a
   hand-instantiated ring (the zirh_env_ro discipline), which needs
   its own bring-up.
3. **SRAM macro hardening at the dedicated floorplan** - the macros
   are proven in behavioral simulation; their PHYSICAL integration
   (PDN to the two-TopMetal stack, guard rings, the GDS-merge
   snags MPW-COST notes) is real flow work.

Everything else is instantiation of verified blocks.

## Scope discipline

Not in ZIRH-3: the C12 full-parallel core (SERV carries the
methodology; the core swap is a later, separable step), the SiP MRAM
integration (a discrete on-board MRAM rehearses the architecture
first), and anything that would grow the die past the free 2 mm2
without a measured reason to. The program's rule holds at the die
level too: add silicon only when data justifies it.

## Pad-ring power budget (hardening-time planning, Cycle 29)

The die today has no pads - that is recorded scope, not an
oversight - but the question "enough ground pins?" deserves numbers
before the padframe exists, so the budget is written from what the
campaigns measured rather than from habit.

MEASURED, die-level: the stitched compute cluster draws 24.4 mW at
1.20 V typ (20.3 mA) by the flow's own estimate; the routed PDN
carries it with 3.54 mV worst IR drop and zero power-grid
violations. The full die adds the 80-macro bank (few macros active
per access) and the periphery; planning bound: 2-3x the cluster,
call it 40-60 mA on the core rail.

That first budget - twelve grounds at a 1:6 ratio - was written
when this die was the compute cluster plus a bank. Cycles 27-38
grew it to 51,651 flops with a 24-channel timer bank that counts
every cycle, three queued SPI masters, two I2C controllers with
slave chairs, a second UART and 56 driven pins. Two of its numbers
went stale at once: the core current it assumed, and the number of
outputs that can switch on one clock edge. Both are re-derived
below, and the ground count moves from twelve to TWENTY-TWO.

CORE RAIL. The measured anchor stands: the stitched cluster draws
24.41 mW at 1.20 V (20.3 mA), 20.72 mW of it internal. What
changed is what surrounds it. Scaling that internal figure by the
die's real flop count - 51,651 total, of which roughly 17.7k are
the behavioral icache arrays that become macros rather than flops -
against the cluster's own, and derating for peripherals that idle,
lands the full-die core rail in a 100-165 mA band. That is AT OR
ABOVE the VA10805's 105 mA typical, not the 40-60 mA the first
budget planned for, and it is the single most important correction
here. It remains an estimate: only a full-die power run on the
routed netlist replaces it, and that run is the open item this
section names.

SIMULTANEOUS SWITCHING. The worst case this design can actually
produce is not a rule of thumb, it is a program: a 32-bit PORTA
store landing on the same edge as a 24-channel PWM rollover puts
up to 56 outputs into transition in the same nanosecond. Take a
3.3 V pad into a 20 pF flight load; a fast pad turns that in about
2.5 ns, so each pad peaks near 26 mA and pushes roughly 21 mA/ns.
With bond wire and lead frame together near 6 nH per pin and M
grounds in parallel, the bounce is (6/M) nH x 56 x 21 mA/ns, and
holding it under a tenth of VDDIO would demand M above twenty
grounds FOR THE IO RING ALONE.

That is the trade this plan makes explicit: the ground count and
the pad's edge rate buy the same thing. Committing the ring to
SLEW-LIMITED IO cells - about 5 ns at 20 pF - halves the di/dt and
brings the same worst case inside twelve IO grounds. The plan takes
that commitment, and the twelve below are therefore contingent on
it: a fast-pad ring needs roughly twice as many.

PLANNED pad pairs, and why:
  core VDD/VSS      8 pairs - two per side. Not for DC (165 mA over
                    eight pads is nothing) but for di/dt and for the
                    ring's IR profile with a TMR'd die whose flop
                    count tripled
  VDDARRAY/VSS      2 pairs - electrically the core rail (the PDN
                    ties them), padded separately so the retention
                    experiment stays possible on the bench
  VDDIO/VSSIO       12 pairs - the SSO derivation above, at the
                    committed slew, for the 56 GPIO at 3.3 V. They
                    must be INTERLEAVED between the GPIO banks, not
                    clumped at the corners: twelve grounds in one
                    corner carry the same inductance as one
  ground total      22 ground pads against 74 signal pads, a 1:3.4
                    ratio - deliberately tighter than the VA10805's
                    1:4.6, because that part's Cortex-M0 carries a
                    few thousand flops against this die's tens of
                    thousands and its ring was characterized on
                    qualified silicon while ours is arithmetic

Signal + power lands at 118 pads (74 signal, 22 VSS, 22 VDD): an
LQFP-128-class frame with ten spare, consistent with the VA10805's
128-pin package carrying the same 56 GPIO plus its larger
peripheral set. The OpenMPW slot's pad budget is the binding
constraint to check when the frame is drawn; if it cannot carry
118, GPIO width is the knob that scales (PORTB drops first), never
the ground count.

WHAT WOULD SETTLE IT. Two runs, neither of which this repository
can do today: a full-die power analysis on the routed netlist to
replace the scaled core-current band, and an SSO simulation with
the real package model and the chosen pad cells to replace the
inductance arithmetic. Until those exist the twenty-two is a
DEFENSIBLE budget, not a measurement, and this section says so.

## Architectural equivalents (datasheet features the open PDK cannot build)

Three VA10805 features have no open-PDK construction; each is
covered by an equivalent this repository can actually verify, and
none is pretended at in the parity ledger:

- eFuse (1 Kb): no fuse technology exists in SG13G2's open kit.
  The equivalent is the MRAM image's CONFIG PAGE - the same
  external rad-tolerant part that holds firmware holds the
  configuration words, read at the autonomous boot (Cycle 38) and
  protected by the same image CRC. Fuses burn once; a CRC'd MRAM
  page survives more radiation than the die does.
- IO configuration (per-pin 33k pulls, glitch filters, inversion):
  pulls and analog glitch filters live in the pad ring, chosen at
  pad-cell instantiation time - recorded as a pad-time decision.
  Inversion and direction are already software's through the GPIO
  block; digital debounce belongs to the timer bank's capture mode.
- Internal ~1.2 MHz oscillator + 30 ms boot delay: the POR/RO
  block already provides the ring oscillator and the counted
  reset delay (POR_CYCLES); the numbers differ, the architecture
  is the same and the delay is a parameter.

## Ground budget: why ratio-matching was the wrong instrument

The VA10805's LQFP-128 carries roughly 19 VSS among ~40
power/ground pins, a ground-to-signal ratio near 1:4.6, and an
earlier revision of this document moved to sixteen grounds simply
to match it. That reasoning was wrong and is recorded here as a
lesson rather than deleted: a ratio says nothing about the two
quantities that actually set the number - how much current the core
draws and how many outputs can switch on one edge. This die carries
an order of magnitude more state than the yardstick's Cortex-M0 and
can put 56 pins into transition on a single clock, so it needs MORE
ground than the part it is measured against, not the same
proportion. The pad-ring plan above derives twenty-two from those
two quantities directly.
