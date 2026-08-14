# ZIRH-3 roadmap - cycle log

## Cycle 0 (2026-08-16): birth with its proofs attached

The repository opens with the verified block library imported at its
proven state from zirh2: the 5-slice SECDED SRAM word with scrubber
and address-in-ECC, its BIST engine, the trusted boot loader with
read-back CRC and revert ladder, the QSPI-MRAM controller, the debug
isolation gate, the clock-loss observer, and the TMR primitive
library that carries the escape-window theorem. Nothing arrives
naked: six cocotb suites, the SV boot-scenario suite (including the
lying-memory storage_lie case), four formal harnesses and a
synthesis-integrity check with MEASURED expectations all run in CI
from the first commit - the hygiene sprint is this repository's
birth certificate, not its aspiration. The program register maps the
owner's 49-item brief onto this repo honestly: INHERITED where zirh2
closed it, HERE where the dedicated die owns it, GATE where a
decision belongs to its owner. The build discipline is stated in
docs/SCOPE.md and enforced by the gate this repo is built around:
integration proceeds, tape-out waits for data.


## Cycle 1 (2026-08-16): CI shaped for the runner budget

The first CI run cancelled at the formal step: a single N=32 ring
k-induction can outrun a shared job's minutes. The fix follows the
theorem, not the timeout - k-induction is N-INDEPENDENT, so N=4 and
N=8 prove containment fully and fast, and the shipping N=32 is
belt-and-braces. CI now runs three parallel jobs (checks, units,
formal) each with its own budget, the formal job proving rings at
N=4/8 plus ECC, address mask and debug lock; the N=32 confirmation
moves to a dispatchable formal-deep workflow, off the per-push path.
The zirh2 formal proof - identical RTL - already carries N=32 in its
own CI, so nothing is lost, only re-shaped to where the minutes live.

## Cycle 2 (2026-08-16): the memory subsystem stands up

The first integration artifact: src/zirh3_memsys.v wires the verified
blocks into one harness-independent subsystem - the trusted loader as
boot master, the 5-slice SECDED bank as the memory it fills (a
stronger demonstration than ZIRH-2's 64 B ECC RAM), the QSPI
controller as the external-MRAM image source, the clock-loss observer
on its independent oscillator, and the debug gate holding the port
locked at POR. It elaborates, lints clean per-block, passes an
elaboration smoke (golden strap leaves the loader in charge, debug
locked, no spurious TMR error at rest), and holds its replicas
through synthesis. The integration replica count (48, down from the
blocks' standalone 72) is documented: this skeleton ties off many
inputs and a constant-input register constant-folds - not a merge -
so the per-block checks stay the authoritative merge guard. The
CPU/SoC cluster import is the next step; this is the substrate it
attaches to.

## Cycle 3 (2026-08-16): the die makes its own reset and clock

The genuinely-new dedicated-die silicon docs/SCOPE.md named, built and
verified: src/zirh_por_ro.v conditions the system reset from the raw
pad reset and a brown-out signal - holds through a settle window,
releases synchronized, re-arms on any power dropout - and generates
the independent ring-oscillator clock the clock-loss observer needs,
the one a TT harness handed ZIRH-2 for free. src/zirh3_die.v is the
standalone-die wrapper: it takes only a pad reset and power-good and
makes everything else itself, attaching por_ro to the memory
subsystem. Both pass elaboration/sequence smokes (settle hold, clean
release, brown-out re-arm; the die self-conditions its reset and
brings the loader up with debug locked), lint clean, and hold through
synthesis - the POR/RO source honestly carries no TMR by design (a
triplicated power-on counter is not the intent; it fails safe by
holding reset) and its plain-flop count is guarded so no replica
sneaks in unnoticed. Z3-R12 enters traceability. The SoC cluster
import is the remaining step; it attaches to this same conditioned
reset and this same subsystem.

## Cycle 4 (2026-08-16): the raw-cross-section instrument (A6)

The second evidence leg the brief names: src/zirh_sram_dut.v drives
five BARE RM_IHPSG13 macros - no SECDED, no scrubber, no voting -
through the proven pattern engine and exposes every mismatch as a raw
(fail_adr, fail_map) record: which address failed and which of the
five macros failed there. That per-macro bit map is what lets a
ground analysis separate single-bit upsets from multi-bit upsets
inside one physical macro - the MBU correlation the brief asks for -
and no published beam data exists for these open-PDK macros, so the
dataset alone is citable. It is the deliberate opposite of
zirh_sram39: same five macros, but here nothing corrects them. The
clean-array smoke is the pre-beam baseline (zero failures with no
radiation - the floor a campaign subtracts); the engine is TMR while
the macros under test are not. Reuses the proven macro binding and
pattern engine unchanged - integration, not new datapath. Z3-R13 in
traceability.
