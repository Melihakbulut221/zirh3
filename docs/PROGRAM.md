# ZIRH-3 program register

The owner's commercial brief (the 49-item obstacle-and-remedy list
that drove zirh2's product program) applied to THIS repository. Three
statuses: INHERITED (closed in zirh2, carried here as living code or
documented method), HERE (this repo's own work), GATE (a decision
with an owner - money, silicon, partners - surfaced and left to them).

## A. Memory - the P0 of this chip

- A1 SRAM macro integration: INHERITED as src/zirh_sram39.v with the
  RM_IHPSG13 1024x8 binding; the P0 HERE is carrying it through the
  dedicated floorplan (LEF/GDS/lib binding, two-TopMetal PDN, the
  GDS-merge and LVS snags the cost study names).
- A2 slicing vs MBU: INHERITED (the 5-slice generate-loop word); the
  slicing-price A/B experiment is a floorplan task HERE.
- A3 background scrubber: INHERITED (TMR + safe-state, scrub_en
  gate); the scrub-period-vs-upset-rate datasheet calculation is
  paperwork HERE once beam rates exist (GATE on data).
- A4 address-in-ECC: INHERITED (even-weight fold; f_amask proof).
- A5 MRAM architecture: INHERITED as src/zirh_qspi.v + the boot
  path; the SiP/MCM packaging ladder stays a GATE (money/supplier).
- A6 SRAM DUT experiment: HERE - the bare-macro cross-section block
  belongs on this die; zirh_sram_bist is its engine.

## B. Radiation characterization

- B7-B9 campaign engineering: INHERITED (zirh2's BEAM-PLAN,
  TID-SEL-PLAN, DUT-BOARD documents apply to this die unchanged in
  method); facility choice and funding stay GATEs.
- B10 shuttle discipline: THE GATE THIS REPO IS BUILT AROUND -
  integration proceeds, tape-out waits for ZIRH-1/2 data.

## C. The product chip

- C11 standalone essentials: HERE - pad ring, ESD, POR/brown-out and
  the hand-instantiated RO for the observer are this repo's honest
  new-design list (docs/SCOPE.md).
- C12 full-parallel core: study INHERITED (Hazard3 primary, picorv32
  fallback); the swap is deliberately NOT in scope here - SERV
  carries the methodology (docs/SCOPE.md, scope discipline).
- C13 characterization: INHERITED method (bench procedure, shmoo
  plan); execution GATEs on silicon.
- C14 the vehicle: the free IHP OpenMPW ~2 mm2 slot (zirh2's
  MPW-COST finding) - the rehearsal costs no money, only data.

## D. Verification-to-certification

- D15 traceability: HERE from day one - requirements.yaml gates CI
  the way zirh2's does; the ECSS-shaped matrix generator carries
  over when the requirement set stabilizes.
- D16 pilot pack / D17 independent review: GATEs (customer, partner).

## E. Commercial sequencing

- E18-E24: INHERITED - the portfolio, positioning and export memos
  live in zirh2 (the program's commercial home) and cover this chip;
  nothing commercial is duplicated here. E22 remains skipped by
  owner instruction.

## F. Programmability, debug, software

- F25/F26 boot + ISP: INHERITED and PROVEN twice - standalone suites
  here, and the UART-host configuration live on the ZIRH-2 die.
- F27 debug module: DONE (Cycle 8 + rungs 5-6) - IEEE 1149.1 TAP +
  RISC-V DTM/DM behind zirh_dbg_gate, with System Bus Access to the
  sliced bank; inert in flight, live on the bench.
- F28 DFT/scan/BIST: DONE (Cycle 13) - MBIST doorway at slot 5 (the
  march engine reachable from ISP-loaded software), boundary scan
  (SAMPLE/PRELOAD + EXTEST behind the flight lock), and the
  post-synthesis scan-insertion flow proven on a pilot block
  (scripts/dft_scan.sh) - full-die insertion remains dedicated-flow
  work at hardening time, on a proven path.
- F29 software ecosystem: INHERITED (HAL over the generated register
  map); grows here as the memory map does.

## G. Test ladder

- G30-G38: INHERITED as method (corner-SDF flow, bench-as-code,
  glitch/TPA plans, statistics, confound protocol, reporting shapes)
  - all retarget to this die when it exists.
- G39 orbit: GATE.

## H. Hygiene

- H40-H49: HERE from the first commit - CI (lint, six unit suites,
  SV scenarios, formal, tmr-guard-style synthesis integrity,
  traceability) is this repository's birth certificate, not its
  aspiration.

## Execution order

1. Keep the imported library green (CI, this commit).
2. zirh3_top integration skeleton per docs/SCOPE.md: soc cluster +
   sram39 + boot/qspi + dbg_gate + clkobs, harness-independent.
3. The named new-design area: POR/reset, RO source, pad ring - with
   the flow work (LEF/PDN/macro placement) that the cost study
   scoped.
4. A6 SRAM DUT block around zirh_sram_bist.
5. F27 debug + F28 DFT, behind the gate: DONE (Cycles 8-13).
6. Hardening trials on the OpenMPW template - the placement recipe
   and its campaign discipline carry over from zirh2.

Everything beyond waits where it should: B10, the data gate.
