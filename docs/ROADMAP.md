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

## Cycle 9 (2026-08-16): rung 3 - the loaded program speaks (ISP end to end)

src/zirh3_top.v is the CPU-carrying top: the imported cluster attached
to the trusted loader through the exact ISP mux ZIRH-2 proved at gate
level - and on this die the loader runs PROTECT=1, because the area
exists here (the ZIRH-2 placement campaign is the record of why the TT
die could not afford it). The reset arrives conditioned from por_ro,
the JTAG module sits alongside behind its gate, the observer watches
from its own oscillator. The rung-3 suite passed 3/3 on the first run,
and its positive proof is the right kind: not a peek at internal
state, but the LOADED program's 'Z' stream audible on the TX pin -
arbitrary code, written by the testbench's own assembler, streamed
over the UART pin, committed by read-back CRC, running where the mask
ROM used to. The negative half holds too: a corrupt image never
selects the bank and the golden ROM's echo comes back; a golden strap
behaves exactly as the standalone cluster suite proved. Full-top
synthesis integrity measures 45 replicas / 2984 flops with every
block's count intact. Remaining named rungs: the sram39 sliced bank
as CPU data memory on a bus slot, the SBA-to-bus route, and the
hk/telemetry cluster with the watchdog-revert signon.

## Cycle 10 (2026-08-16): rung 4 - the sliced bank is the software's memory

zirh_soc exports a second bus slot (0x4000, mirroring the proven s3
pattern) and the five-macro SECDED bank sits on it as CPU data memory:
a loaded program writes it, reads it back through the corrected port,
and shouts the verdict byte on the TX pin - 'Z' only if the round trip
matched. The bank the beam campaign will scrub is now the bank the
software actually uses, which is what makes its counters mean
something. The hunt was the cycle's real story: the lw kept latching
X and five probes walked the blame down the stack - commit was clean,
the CPU was alive and looping, the write acked full-word at row zero,
and the macro STILL read X - until the compile line confessed: the PDK
macro's behavioral write path lives behind a FUNCTIONAL define the new
makefile didn't carry, so the model swallowed writes silently and
every read was X. The proven sram39 suite had the define all along;
the fix is one line and the lesson is the night's oldest - a model
that accepts a write without storing it is another tool returning
success without doing the work. Suite 4/4; full-top integrity at 51
replicas / 3253 flops; Z3-R17 in traceability. Remaining rungs:
SBA-to-bus, hk/telemetry with the watchdog signon.

## Cycle 11 (2026-08-16): rung 5 - the debugger reaches memory, through the gate

The JTAG System Bus Access master now reaches real memory: a small
priority arbiter at the top lets the debugger's gated SBA read and
write the sliced bank while the CPU is running, without halting it.
The priority is safe by construction - SBA can only assert its cycle
UNLOCKED, and the gate forces it inert in flight, so a flight CPU
never contends with a debug peek. The smoke proves both halves: with
the fuse set, a JTAG debugger pokes 0xBEEF into the bank and reads it
back through the corrected port; with the fuse clear, the gate holds
the whole SBA master inert and a word seeded while unlocked survives
an attempted overwrite while locked. Two authoring bugs surfaced and
were fixed on the way - a DMI payload that padded the 2-bit op field
to 8 bits, shifting the address and data fields (found by probing the
DMI decode, exactly the value the earlier JTAG cycle taught), and the
FUNCTIONAL define the bank needs. The arbiter is combinational, so the
top holds at 51 replicas / 3253 flops. All three debug/programming
paths are now not just present but exercised end to end through their
boundaries: ISP load, JTAG halt, and JTAG memory access. Z3-R18 in
traceability. The remaining rung is the hk/telemetry cluster with the
watchdog-revert signon.

## Cycle 12 (2026-08-16): the last rung - the die is whole (hk + telemetry + revert)

The final import rung: the housekeeping/telemetry cluster arrives (hk
on slot 3, the tlm2 framer on the shared UART) and the watchdog-revert
signon completes the boot contract this program has named since the
start. A loaded bank that writes its signature signs on and runs; a
loaded bank that never signs on is failed by the CPU watchdog after a
grace period and reverted to the immutable ROM. Unprompted v2
telemetry frames now flow on the UART with a valid XOR checksum and a
living, changing CPU signature - the instrument reports and the
computer lives, on this die's own composition. Four blind hunts fell
to measurement, each the night's refrain: the CPU watchdog at
WD_LIMIT_LOG2=15 starved the bit-serial CPU during boot (it could not
reach its first signature write before the watchdog reset it - a
reset loop, cured by matching the window to the boot time); jtag_err
read X because TCK never ran in this test (observability only, but
named); the frame capture mistook a busy-stream desync for a silent
line and gave up on the first garbage byte; and isp_hold reasserted
after a watchdog revert - boot_strap high and bl_sel back to zero
would have pinned the golden CPU in reset forever, so a
watchdog-failed bank now counts as a reject it will not re-hold for.
Suite 6/6, the full die at 70 replicas / 4192 flops with every block
intact, three lint layers clean. The SoC-import ladder is complete:
the die boots ROM or a loaded image, runs code in its ECC-protected
bank, reports on telemetry, reverts a bad bank, and offers ISP and
JTAG - each behind its own protection boundary. Z3-R19 in
traceability. What remains is not integration but the GATE the
repository was built around: B10, silicon waits for beam data.

## Cycle 13 (2026-08-16): F28 - the die learns to be tested (DFT)

Design-for-test, in the three forms that fit a rad-tolerant open-PDK
die rather than the one form the textbook lists first. MBIST: the
march-test engine the bank has carried since bring-up gets its
doorway - one small bus slave at slot 5 - and the manufacturing-test
program becomes what every program on this die is: data, loaded over
the ISP, its 0xB1 verdict audible on the UART pin, an in-flight
self-test one firmware loop away. Boundary scan: the TAP we already
own gains SAMPLE/PRELOAD and EXTEST over a 12-cell register spanning
every functional pin, and the pin-drive effect obeys the same
absorbing flight lock that guards halt and SBA - interconnect test on
the bench, an untouchable pin ring in flight. And the scan-insertion
rehearsal: the dedicated-die path to full scan proven end to end on a
pilot block without touching one line of verified RTL - yosys to real
SG13G2 cells, every flop swapped for its scan sibling, one chain
stitched in deterministic order, and the stitched netlist PROVEN by
simulation on the foundry's own cell structure: all 48 of the
observer's flops in the chain, shift identity intact, and the capture
cycle reading back the true reset state (the three reset-to-one flops
answer as the only ones).

The cycle's real find was none of these: the boundary-scan bench, the
moment it started CHECKING the err pin, exposed that a die which
never sees a debugger powers up with its TAP state undefined - and
that undefinedness leaks through the DMI update level into the DM's
TMR replicas and recirculates there forever. On silicon the same
mechanism is a random power-up TAP state that could fire a spurious
DMI write before any tool attaches. The fix is the standard one this
program keeps rediscovering from first principles: the POR resets
everything, the TAP included. Two prior benches had run over that X
for three cycles without seeing it; the lesson stands - a signal no
check reads is a signal no test protects.

Guard counts moved with the RTL and were re-measured: the DM at 331
flops (the boundary register), the die at 1333, the top at 70
replicas / 4219 flops, the MBIST doorway's mode register at 3/8. All
suites green: top 7/7, SBA, boundary scan, JTAG, soc 3/3, die; three
lint layers clean; 22 requirements, 0 orphans.

## Cycle 14, rung 1 (2026-08-16): the compute upgrade - the new core breathes

The program's next horizon is VA10805-class throughput (the ~45 DMIPS
a Cortex-M0 at 50 MHz delivers), and the ladder to it starts here.
VexRiscv_Lite - RV32IM, cacheless, pre-generated plain Verilog from
litex-hub/pythondata-cpu-vexriscv (provenance pinned in the vendored
header) - measures 2254 flops at synthesis: forty times SERV's
throughput class for a protection budget that still fits this
program's methods, whether as netlist-level flop triplication (the
DFT stitcher's machinery, one voter deeper) or as core-level TMR.
The core arrives already speaking Wishbone classic on both buses -
the soc's native contract - so zirh_vex_wrap is thin by design: byte
addresses, CYC qualified by STB, one reset-polarity inversion at the
boundary, the runtime reset vector passed through (the ROM/bank boot
mux, in hardware, for free). The smoke bench hand-assembles a
program and proves the four things the soc swap will lean on: fetch
runs, stores land, a MUL returns 42, a load round-trips. Two of the
bench's own hand-encodings were wrong before the DUT ever was - the
S-type immediate split once, an rs2 field once - both found by
probing the pipeline, which reported the core doing exactly what the
bad words asked. The next rung swaps this core into zirh_soc behind
the same suites that guard SERV today.

## Cycle 14, rung 2 (2026-08-16): the core swap - forty times the computer

zirh_soc runs VexRiscv_Lite. The exchange itself was one
instantiation - the wrapper was shaped for it - plus the one
assumption a pipelined core breaks: instruction and data traffic in
the same cycle, so the bank-mode fetch ack now yields to a data-bus
collision instead of assuming one cannot happen. The golden ROM
firmware booted the new core UNCHANGED on the first run: the soc
suite passed 3/3 untouched, and the bank, MBIST, SBA, boundary-scan
and telemetry proofs followed. The guard re-measured at 22983 flops
with a documented caveat: ~17.7k of them are the instruction-cache
array, which memory_map renders as flops exactly as it renders every
behavioral memory - at hardening it binds to an SRAM macro like the
bank's five slices.

Three tests failed, and the hunt through them is the rung's real
story, because the DUT was never wrong. The echo tests probed clean
at every layer: the receiver took the command, the firmware answered
within ~260 cycles, the arbiter held the telemetry frame atomic and
put the echo on the wire the moment the frame ended. What broke was
the LISTENER: a capture that tunes in mid-frame locks onto a payload
bit as a start bit and never recovers alignment - and the bit-serial
core's slowness had hidden that race for the suite's whole life,
because its echoes arrived tens of thousands of cycles after any
frame. The fix is the ground station's own discipline, now in
hunt_echo: align on an idle gap, send from alignment, consume frames
atomically, resend when a reply is lost. A faster computer did not
just speed the chip up - it sharpened the tests that watch it.

Throughput arithmetic for the record: RV32IM at ~1 DMIPS/MHz-class
IPC against the bit-serial core's ~1/40th - the VA10805-parity
ladder's compute leg is climbed at equal clock, and the 50 MHz
closure campaign remains as the clock leg.
