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

PLANNED pad pairs, and why:
  core VDD/VSS      4 pairs - one per side; 60 mA is trivial for a
                    single pad, DISTRIBUTION and loop inductance are
                    what the four-sided spread buys
  VDDARRAY/VSS      1 pair - electrically the core rail (the PDN
                    ties them), padded separately so the retention
                    experiment stays possible on the bench
  VDDIO/VSSIO       7 pairs - the SSO rule (one pair per ~8
                    simultaneously switching outputs) applied to the
                    56 GPIO at 3.3 V; UART/JTAG/events are slow and
                    ride the same rail without adding pairs
  ground total      ~12 ground pads against ~74 signal pads, a 1:6
                    ratio - conservative against the 1:8 SSO rule

Signal + power lands near 98 pads: an LQFP-100/128-class frame,
consistent with the VA10805's 128-pin package carrying the same 56
GPIO plus its larger peripheral set and its own power population.
The OpenMPW slot's pad budget is the binding constraint to check
when the frame is drawn; if it cannot carry 98, GPIO width is the
knob that scales (PORTB drops first), not the ground ratio.

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

## Ground budget revision (datasheet-informed)

The VA10805's LQFP-128 carries roughly 19 VSS among ~40
power/ground pins - a ground-to-signal ratio near 1:4.6 against
this plan's original 1:6 budget. The pad-ring plan moves to
sixteen grounds (~1:4.6) to match the yardstick's measured
practice; SSO analysis at pad-time makes the final call.
