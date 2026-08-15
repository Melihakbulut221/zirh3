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

## Cycle 5 (2026-08-16): the SoC cluster arrives, lint-clean (import step 1)

The first rung of the SoC-import ladder (docs/SOC-IMPORT.md): the
SERV-based computing cluster is now present in the tree and
warning-clean. SERV 1.3.0 (17 files, vendored unmodified, pin in
src/serv/VERSION) plus the mask ROM and its committed firmware, the
single-master bus with its watchdog, and the command/telemetry UART
path - and zirh_soc.v, which already carries the ISP fetch mux built
for ZIRH-2 (the exact port that will attach the CPU to this repo's
loader and sliced bank). It elaborates as one design and lints clean
under the same policy: SERV is vendored and exempt, only zirh-authored
soc-layer warnings fail the build, and there are none. The CPU cluster
is proven-present; the remaining ladder rungs (retarget the SoC cocotb
suites, attach to the memsys bank via the proven mux, full-die
synthesis integrity) are the next focused step, and the plan makes
each one assembly.

## Cycle 6 (2026-08-16): the imported cluster RUNS (import step 2)

The second ladder rung: the SoC cocotb suite retargets and passes 3/3
- boot, echo through the pins, and the living-CPU contract - on the
imported cluster in this tree. Two rots were found and fixed on the
way, both instances of the night's refrain. First, the suite itself
had been failing in zirh2 since the ISP ports landed (undriven inputs
flooding X) and nobody knew, because it was never in CI - fixed in
zirh2 and added to its CI so it cannot rot silently again. Second,
the firmware image: the suite loads fw/rom.hex, which had not come
over, and $readmemh fails SILENTLY, leaving the ROM X and the CPU
dead at its first fetch - the file is now part of this repository.
The cluster boots the committed firmware and answers on its pins;
rung 3 (attach it to the memsys bank through the proven ISP mux) is
next.

## Cycle 7 (2026-08-16): the programming interface reaches a pin

Owner review caught two things at once. First, the diagram had
dangling arrows - rails ending in empty space, observability pills
with no wires - now every net terminates where it belongs and all six
status pills ride one trunk. Second, and more substantively: the
host-ISP transport was a byte-stream PORT, not a pin - the UART
receiver (zirh_isp_rx, proven on the ZIRH-2 die) had not come over.
It is now on this die too: uart_rx_i is a pin, the receiver runs at
the reset baud under the conditioned reset, and strap 11 selects it
as the loader's transport with QSPI as the other. The die smoke
passes unchanged, the die measures 1009 flops with replicas still at
48, and the diagram now shows the interface the silicon would
actually have. A diagram review that finds a missing block is a
design review - which is what the figure is for.

## Cycle 8 (2026-08-16): the JTAG debug port, behind the gate (F27)

The debug interface the owner asked for, built to the program's own
rule: it exists on a flight die only because the isolation gate makes
it safe. src/zirh_jtag_dm.v is an IEEE 1149.1 TAP speaking the RISC-V
external-debug transport - IDCODE, DTMCS, and DMI carrying
{address, data, op} - and a compact Debug Module that turns dmcontrol
writes into halt, ndmreset and a System Bus Access master. The TAP
and shift registers are a TRANSPORT, deliberately not triplicated
(like the ISP receiver); the DM's persistent control state IS TMR,
because it is what reaches the system - and everything it produces
passes through zirh_dbg_gate, latched locked at POR unless the flight
fuse permits debug. The smoke proves exactly that boundary: IDCODE
shifts out correct, a haltreq written over JTAG is held inert by the
locked gate (the DM asks, the gate refuses), and the same request
reaches the core only once the fuse is set. On the die: uart_rx for
host ISP, QSPI for MRAM, and now TCK/TMS/TDI/TDO for JTAG - all three
programming and debug paths the brief named, each protected at its
boundary. The clock-domain crossing from TCK to the system clock was
the one real snag - a tck-domain toggle hit the classic non-blocking
read race (the TB saw the condition true while the module's identical
condition did not fire); a level synchronized across the whole
UPDATE_DR tck period, free of the race, fixed it. The SBA-to-bank
memory path is produced but not yet routed - a follow-on rung; the
halt/reset path through the gate is the F27 core, and it is proven.
