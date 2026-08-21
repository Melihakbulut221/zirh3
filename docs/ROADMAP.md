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

## Cycle 14, rung 3 (2026-08-16): the protection pilot - two answers, measured

How do you protect a pipelined core you must not edit? Both answers
now exist in this tree, proven on real SG13G2 cells. Pilot A wraps
three vendored cores behind one voted bus: a corrupted core diverges
silently behind the voters - two thousand cycles of wrong intent
never touching memory - and the sticky divergence flag hands
recovery to the reset ladder the die already trusts. Its price is
the honest limit that a diverged core stays diverged. Pilot B is
zirh_tmr_reg's voted feedback applied by TOOL: the scan stitcher's
machinery one voter deeper, tripling every flop in the synthesized
netlist and giving the voter the original Q net, so every consumer -
the combinational cone and each replica's own D path - reads the
majority. The stitched carrier tracks its golden model, masks a
pinned replica, and HEALS it on release: the self-correcting
property the RTL library has carried since ZIRH-1, now available to
logic the RTL never wrote. The core transform measures 3.5x cells
with the caveat written down: most of those flops are the
instruction-cache array, which hardens as a macro, not as
triplicated logic - the true cost is the ~2.3k core-state flops.
The decision is deliberately deferred to measurement: pilot B is the
program's philosophy and the default; pilot A is the fallback if the
per-flop voter's timing cost breaks the 50 MHz closure. The clock
campaign - the parity ladder's remaining leg - picks the winner.

## Cycle 14, rung 5 (2026-08-16): the storage leg - 64 KB, and the bench grows branches

The data bank grows sixteenfold without one proven line changing:
zirh_bank64 composes sixteen copies of the sliced-SECDED bank - 80
macros, every word 32+6+1 across five slices, every page scrubbed -
behind a TMR'd page register in the slot-5 doorway. The CPU pages
its 4 KB window (one store to switch context; the bus map and the
golden ROM stand untouched); the debugger's SBA reads the flat
64 KB; the march engine follows the page select. The loaded-program
space grew alongside: the ECC RAM parameterizes to 128 words and
the loader's banks to 64 each, four times the ZIRH-2 image budget.
Synthesis and the guard always build the full sixteen pages (73
replicas / 31406 flops, measured); simulation suites build four -
the paging mechanism is page-count agnostic and the wall-clock is
not.

The proof fought back, and every round sharpened something. The
image was rejected: the loader's capacity check said 61 words and
the hand-count said the program was 62 - the bench's third encoding
lesson of the cycle. Then the verdict bytes read wrong on the pin
while every probe inside the die read RIGHT: page 2 returned 0xAA,
page 3 returned 0xBB, the CPU computed and wrote 0xB5/0xB6, the
shifter accepted exactly those bytes onto the wire - and the
listener still read 0xB3/0xAB, because a program that floods the TX
slot saturates the line and a saturated line gives a naive sampler
no gap to align in. The fix is the product's own discipline, now in
the bench's assembler: branches. The runner polls TX_FREE like the
firmware does and paces itself with a real delay loop, the line
idles between bytes, and the listener reads what the wire carries.
The bench that started this cycle with four opcodes ends it with
nine and a calling convention.

The storage gap to the VA10805 closes to its last item: 64 KB of
SECDED data bank against its 32 KB of bare data SRAM - ours is now
LARGER and protected; program-store scale (256 KB class) remains
the one open storage line, and it is the same pattern at more
macros.

## Cycle 15 (2026-08-16): the 50 MHz P&R campaign opens

The synthesis leg measured 21.7 ns typ on gate delays alone; wires
get their vote through the dispatchable pnr workflow - LibreLane on
SG13G2, the exact toolchain-and-discipline the zirh2 nine-round
placement campaign proved, now pointed at the compute upgrade. Round
one hardens the timing pilot (the cacheless Min core under the
shipping wrapper: the pipeline's real path, the cache arrays kept
for macro-bounding) at CLOCK_PERIOD=20 with flow-default knobs -
knob archaeology begins after the first measured failure, not
before. The corner slacks print in the workflow log; the campaign
iterates one knob per round with verdicts recorded where the knobs
live, and the shipping Lite core follows once the cache arrays get
their RM-macro binding.

## Cycle 15, round 2 (2026-08-16): 50 MHz closes on the first placed round

Round 1 died in the yosys-check gate - three generated-but-undriven
stub nets, tied off as a marked patch in the pilot file. Round 2
went to the tools clean and returned the campaign's verdict in one
pass: setup worst-slack +4.53 ns AT THE SLOW CORNER (+8.86 typ),
hold positive everywhere, zero violations - 50 MHz closed with
default knobs, no archaeology required. The synthesis leg's 21.7 ns
scare was abc mapper pessimism, not silicon truth: the flow's real
post-route path is ~11 ns typ, and the pipeline could chase the
60-75 MHz class if a future rung wants it. Standing consequences:
the protection choice is timing-free beyond doubt (pilot B's 81 ps
voter rides on 4.5 ns of worst-corner slack), and the VA10805
parity ladder's clock leg is CLOSED at the pilot level. The
campaign's remaining named work is the shipping Lite core with its
cache arrays bound to RM_IHPSG13 macros - integration, not risk.

## Cycle 15, the campaign record (2026-08-17): 50 MHz closes on the shipping core

Twenty-two rounds, every verdict written where its knob lives. The
macro-bound shipping core - VexRiscv_Lite with its cache arrays on
real RM 2P macros - places, routes with zero overflow, passes
routing DRC, and closes 50 MHz SETUP with +5.44 ns at the slow
corner (+9.3 typ, +11.6 fast). The road there: a checker's stub
nets, a PDN that needed channels, the zirh2 campaign's placement
island and post-CTS resizer failures reproduced and cured by its
own book, congestion peeled in three layers (real estate, halo,
and finally the truth - the macros' pin face looking at the die
edge; one FS flip took the overflow to zero), floating macro power
rails, and three signoff-tool frictions parked where zirh2 parked
its own.

What remains is named and bounded: a hold residual of -0.38 ns at
the fast corner (typ -0.22, slow +0.02) on exactly 26 endpoints,
all at the macros' data inputs where RM internal clock latency
shifts the capture edge. It survived every legitimate knob the flow
offers - the margin seesaw measured at four points, the repair
budget, and an SDC scalpel that taught us set_min_delay redefines
the check instead of driving the repair. Hold does not scale with
the clock, so this residual gates TAPEOUT, not the 50 MHz claim:
the closure work belongs to signoff - an ECO pass with explicit
buffers on the named nets, or clock-tree balancing into the macro
clock pins - and it is the compute upgrade's one open physical
item. The parity ladder's clock leg stands closed at the level
that owns it.

## Cycle 16 (2026-08-18): the hold ECO - every corner closes

Six rounds on signoff's own terms. The instrument: OpenROAD
repair_timing on the final ODB inside the flow's own image, iterating
on the campaign baseline's artifact instead of re-running the
fifty-minute chain. The road taught its own lessons: a 503 is
weather; a die sealed with thirteen thousand fillers has no room for
new buffers until remove_fillers reclaims their sites; a before that
speaks SPEF and an after that speaks GRT estimate judge by different
rulers; one thread routes no die in time; and five changed nets do
not justify rerouting twenty-eight thousand cells - the original
SPEF re-annotates the unchanged world and the new buffer nets ride
where intrinsic delay dominates, honestly labeled.

The verdict, three corners in one session: before -0.39, after
+0.15 with setup untouched at +5.05 slow. Nine endpoints, fourteen
hold buffers, legal placement, resealed rows. THE MACRO-BOUND
SHIPPING CORE NOW CLOSES 50 MHz AT EVERY CORNER. The compute
upgrade's physical story is complete: IPC parity, clock closed,
protection chosen and free, 64 KB of protected storage. What the
parity ladder still owes VORAGO is program-store scale - and B10
still owns the silicon decision.

## Cycle 17, rung A (2026-08-18): programs live in the bank now

The parity ladder's last line begins. The loader's address builder -
sized for the ZIRH-2 die's 512-word banks and silently truncating
any larger base to zero - generalizes to the width BANK_WORDS asks;
the soc exports its boot fetches; and the top grows the four-master
arbiter the architecture wanted all along: debug over loader over
data over fetch, every full-address master reading the bank FLAT
while the CPU's data window keeps its page register. Loaded images
land in the same scrubbed, sliced-SECDED array the beam campaign
will interrogate, and the CPU runs them from there through its
cache. The ECC RAM returns to what its name said: slot-1 data
scratch. Eight of eight on the first run of the new architecture,
with the two test adaptations the move itself demanded - the march
now owns a page the fetch path is not standing on, and the bank
probe pokes word 256 instead of its own first instruction. Rung B
deepens the slices (4096x8, the same eighty macros) to 256 KB.

## Cycle 17, rung B (2026-08-18): 256 KB on the same eighty macros

The slices deepen instead of multiplying: DEPTH=4096 swaps the RM
1024x8 for the 4096x8 in the same five-slice, one-word geometry, and
the sixteen instances become 256 KB - banks A and B at 128 KB each,
four times the VA10805's program store, protected where its is bare.
The address-in-ECC fold widens to twelve bits in a form that is
BIT-IDENTICAL at the proven default depth, so the standing formal
proof keeps its subject; the CPU window pages in six bits (instance
plus sub-page); the march unit becomes the 16 KB instance, and the
MBIST runner learned the manufacturing tester's manner - it pets the
watchdog while it works, because a test that kills its own computer
proves the wrong theorem. Suites 8/8, boot, soc, SBA, boundary scan
and the SV stories green; guard re-measured at 76/31761.

THE PARITY LADDER IS CLIMBED. Against the VA10805: IPC at parity,
50 MHz closed at every corner through P&R and ECO, protection chosen
and measured free, 64 KB then 256 KB of scrubbed SECDED storage
against 288 KB of bare SRAM, programs loaded into and run from the
protected array. What VORAGO still holds is what silicon holds:
process-level SEL immunity, qualified corners, a shipping part. That
is B10's business - and B10 waits for beam data, as it always has.

## Cycle 18 (2026-08-19): the deferred theorem, proven on the routed truth

Four rounds of building the instrument that could speak the verdict.
The stale wires of the ECO's split nets hung the router for five
silent hours - stripped, with placement kept exact, because the
wires were being rebuilt regardless. The extraction model the tcl
had picked was the PDK's 'if you feel lucky' alternate, and luck
read fourteen nanoseconds of fiction - the flow's own pattern rules
restored the campaign's numbers to the digit. And the original
SPEF's re-annotation turned out to have flattered the repair: +0.15
estimated became -0.53 routed, because wires rebuilt from scratch
carry different truth than wires remembered.

So the confirm became what signoff already knew it must be: a loop.
Route the exact layout, extract the truth, and when the truth says
the repair undershot, repair against the truth and route again.
Pass one measured the flattery; the loop inserted two more hold
buffers - sixteen now stand; pass two read HOLD +0.16 AND SETUP
+4.71 AT EVERY CORNER, routed and extracted. The gate printed the
sentence this cycle existed for: the ECO'd layout closes at every
corner. The compute die's physical story has no open items left
above the silicon itself - and the silicon waits, as ever, on B10.

## Cycle 19 (2026-08-19): the TMR'd core boots at gate level

The stitcher had a 16-flop proof and the boot story had an RTL
proof; this cycle made them meet on 2138 flops of real SG13G2
gates - and the meeting was not polite. The first wound test
PASSED, and that pass was a lie: the telemetry engine free-runs,
its frame header opens with 0x5A, and a hunt that accepts one byte
declares a dead CPU alive. The honest discipline - three 0x5A in a
row, because the loaded program floods and a frame follows its sync
with 0x33 - plus a majority-wound CONTROL that must fall silent,
turned the hollow pass into a hard fail and the fail into a find:
the stitcher allocated fresh bit ids above the highest CONNECTED
bit, but netnames keep ids the opt passes already dropped, and the
colliding fresh bits came out of write_verilog as alias assigns -
raw replicas and voter internals leaking onto stale nets. The
carrier was simply too small to collide.

One seed line later the whole ladder holds: the unstitched netlist
floods (the cell-model mix is real), the stitched netlist floods
(the stitch preserves the machine), the rail-B wound - every B
replica forced wrong from before POR through the whole boot,
strictly harsher than any single upset - boots, commits, floods,
and on release heals 2138 of 2138 replicas and keeps speaking; and
the majority wound kills the machine, which is what proves the vote
was load-bearing all along. The RTL boot test inherited the flood
discipline too - its old hunt carried the same latent weakness.
Two proofs of the method in one cycle: the test that cannot fail
is the one you fix first, and a protection scheme is only as real
as the netlist transformation that installs it.

## Cycle 20 (2026-08-20): the stitched netlist survives place-and-route

Cycle 19 proved the TMR'd core in simulation; this cycle asked the
harder half of the question - does the protection survive contact
with the physical flow, and what does it cost? Six rounds answered.
The voters became real library cells so synthesis could be disabled
outright, because a resynthesis pass would prove the three replicas
identical and collapse the TMR it was asked to place. A sim netlist
turned out not yet to be a P&R netlist: ten thousand alias assigns
and four constant port bits had to become names something reads and
tie cells. The flow then completed and told the price plainly:
206k square microns of cells become 512.5k - 2.49x - and setup
still closes everywhere at 50 MHz, with fast-corner hold owing
0.156.

Cycle 18's signoff instrument collected that debt, and redesigning
it for this die taught three lessons the record keeps: judge the
flow's own wires before stripping anything, because a from-scratch
reroute wobbles 0.3-0.4 ns and round 3 chased that noise; repair
whatever the truth says is broken, because a hold-only arm built
under five nanoseconds of setup margin drowns on a die with 1.5;
and give the setup arm its wire RC, because hold buffering never
asks and setup rebuffering dies without it. The closing pass reads
HOLD +0.19 / SETUP +2.58 AT EVERY CORNER, routed and extracted.

The cycle also caught a guard asleep: a replica check that printed
zero and passed anyway - its instance grep erased by the netlist
writers, its test chain exempt from bash -e. The honest witnesses
were the stitcher's rail NETS, alive by name in the routed DEF:
2138 tmrA, 2138 tmrB, 2138 tmrC, voter topology readable per net,
now counted at both gates of the seal run. A guard that cannot
fail guards nothing - the same sentence Cycle 19 wrote about the
telemetry-contaminated hunt, earned twice in two cycles.

## Cycle 21 (2026-08-20): the layout's own netlist boots

The last gap in the protection story was between two artifacts:
Cycle 19 proved the netlist we HANDED to the flow, Cycle 20 proved
the flow closes timing on it without killing the triples - but the
thing that will be fabricated is neither; it is the database the
flow handed BACK, thirty hold buffers, a clock tree and two setup
repairs later. So the confirmed database was made to speak for
itself: write_verilog on the sealed ODB, physical-only cells
dropped, and the layout's own netlist ran the same wound trio as
its ancestor - clean flood, every B replica forced wrong from
before POR and healed 2138 of 2138 on release, the majority wound
falling properly silent. The rails survived every transformation
by NAME, netlist text to routed DEF and back, which is what made
one bench serve three cycles unchanged. What was handed to the
flow, what the flow closed, and what the flow handed back are now
one proven thing.

## Cycle 22 (2026-08-20): the parity ledger gets its price tags

The VORAGO comparison had feature rows; now it has physics. From
the campaign's own routed layouts, same flow and corner: the
protection costs 2.44x standard-cell area, 2.10x die and 3.04x
power (8.02 to 24.41 milliwatts, tool-estimated) at an unchanged
50 MHz - the measured price of TMR carried in logic instead of in
process. docs/PARITY.md holds the ledger, states its scope
honestly (cluster vs finished MCU, estimate vs datasheet), and
refuses the two comparisons the data cannot yet support: power
against the VA10805's DC tables, and radiation against HARDSIL's
heritage - both wait, correctly, behind B10.

## Cycle 23 (2026-08-20): the signoff legs come back online

The timing campaigns turned three judges off and filed the reasons;
this cycle collected them. Magic DRC stays filed - a 1.76-million
error storm from scanning foundry SRAM layout with the wrong tech
is the foundry deck's job, not ours. The other two came back. The
GDS-merge question answered itself emphatically: magic and klayout
each merge the RM macro GDS into the die by independent code paths,
and the two results XOR to ZERO shapes across 38 layers - a
75-second judge that now gates the workflow. And LVS, run as raw
netgen inside the flow's own container so the harness's JSON crash
never enters the path, returned the best verdict available to an
abstract-view extraction: every device matched exactly, 36232 to
36232, both macros one to one, and the only mismatches are two
tool-view frictions with names and root causes - the RM power pins
that LEF and verilog spell differently, and four constant address
bits netgen admits it cannot tell apart. The gate now PINS that
ledger; the day a new mismatch class appears, the job goes red.
The cost study's two named snags are enumerated, understood, and
fenced - which is what pre-work is for.

## Cycle 24 (2026-08-20): the rain

The wound trio was proof by overkill - a whole rail dead for a whole
boot. Orbit is not like that; orbit is one bit, one flop, one bad
moment. So the rain: random single-replica upsets, one clock each -
which is a real SEU's whole lifetime under voted feedback, because
the next edge reloads the voted word - landing at random moments
while the machine loads its image and starts its program. Every
shot is verified to LAND (a rain that does not touch the state
proves nothing) and verified to HEAL two clocks later.

The first storm failed its own thinness gate: 53 of 66 slots fell
on flops still reading X - unreset datapath state the machine had
not touched yet - and 13 shots is not a campaign. The gate that
refused to pass a hollow storm is the same sentence this program
keeps earning; an X pick now costs a redraw, not a slot. Three
storms then ran: 314 shots, A, B and C rails drawn evenly, 314
healed, zero divergence - image committed, flood alive, every time.
Stage 7 of the ladder now rains on every push.

## Cycle 25 (2026-08-20): the whole die on gates

Cycle 19 put the CPU on gates inside an RTL die; the die itself
still enjoyed the benefit of the doubt. No longer: loader, bank
arbiter, telemetry, watchdog, debug gate, POR - all of it
synthesized to SG13G2 cells, with the stitched CPU linked into its
socket as a blackbox boundary and the SRAM macros behavioral as in
every simulation. Two decisions made the proof cheap. The netlist
keeps its hierarchy, so u_soc.u_cpu keeps its name and the wound
trio and the SEU rain ran against the full gate die without
changing a line. And the parameters and ROM hex are baked in with
chparam - which taught its own small lesson, because chparam after
hierarchy asks a later elaboration to derive from base modules that
hierarchy already deleted, and the error message says none of that.

The full gate die boots the flood in forty-three seconds of wall
clock, the rail-B wound heals 2138 of 2138 on it, the majority
wound falls silent on it, and the rain lands 106 shots and heals
every one. The die stopped being a diagram hosting a proven core
and became the proven thing itself.

## Cycle 26 (2026-08-20): the storms

Eight curated scenarios ask the questions their authors thought of;
a seeded storm asks the rest. Two storms now run on every push: the
loader fuzzed at its own boundary - random images, lying memories,
streams cut mid-byte, resets mid-load, watchdog failures, 120
episodes per seed under continuous invariants and a liveness
cadence - and the whole die fuzzed at the pins with the CPU running
and telemetry flowing.

Both storms paid for themselves before ever passing. The top storm's
first draft assumed the loader keeps listening, and the die said no:
the loader rules ONCE per reset - commit lands it in S_RUN, reject
in S_GOLDEN, and at flight straps both are deaf to further images;
live A/B re-load listens only at the ISP strap. An unstated contract
is now a stated one, locked by oracles. Then the fixed storm failed
three seeds in a row anyway - and this time the die was innocent:
checking a flood WHILE it streams has no silence to align from, and
a mid-frame lock reads the same wrong byte forever. hunt_echo's
docstring predicted that trap years before it bit the bench that
carried it. The cure is an alignment-free bit-level signature
search, and the closure gates hold: every armed and closed bin
filled, every kind drawn enough to count, deterministic per seed.

## Cycle 27 (2026-08-20): 56 pins, same split

The parity ledger had one row where the yardstick simply had more
chip: VORAGO's 56 configurable GPIO against our zero. Slot 6 closes
it - PORTA 32 and PORTB 24, the same split, with this die's
discipline instead of a catalog's feature list: OUT and DIR are
TMR'd because a flipped direction bit is a fighting driver and a
flipped output bit lies to whatever the pin commands; inputs cross
two flops because pins are asynchronous by definition; the block's
error joins the die aggregate like every control register here.

The proof is end to end: an ISP-loaded program - arbitrary code,
written after tape-out - drives a pattern out of PORTA, opens all
32 drivers, reads what the bench holds on PORTB through the
synchronizers and floods its verdict on the UART. The debug session
that preceded the pass was its own small lesson in trusting the
right suspect: the die had done everything correctly and the bench
was reading a mid-stream flood with a byte-aligned hunt - Cycle
26's alignment trap, met again within hours, cured by the same
signature search. The pad ring will fold each o/oe/i triple into
one bidirectional pad at hardening; 56 pads joins the pin budget
the OpenMPW slot must carry.

## Cycle 28 (2026-08-21): the stitcher leaves the trusted base

Every proof so far TESTED the stitched core; this one proves it.
Two legs, decomposed honestly. At carrier scale the whole chain -
RTL elaboration, abc mapping, the stitcher - sits inside one
equivalence, sixteen points, closed in a tenth of a second. At core
scale the theorem is the TRANSFORMATION: the pre-stitch netlist
against the stitched one, 2639 equivalence points - every flop
boundary via the stitcher's own bookkeeping, every port, every pin
of the macros cut to the boundary - 311 proven combinationally and
2328 by induction, all of them, in two minutes eleven seconds.

The instruments earned trust the usual way. The cell functions are
GENERATED from the PDK liberty, because the simulation models hide
behind UDP tables no formal front end reads and a hand-written
library is a place for bugs to live. The first pilot run returned
in a tenth of a second with nothing proven and nothing failed - a
vacuous pass, refused by its own gate, which now demands the point
count the design implies. And the voter-pin archaeology (Y in the
generic era, X since the voters became real cells) reminded the
cycle that instruments age with the code they measure. The chain of
custody now reads: RTL proven equivalent to gates at pilot scale,
gates proven equivalent to stitched gates at full scale, stitched
gates proven to boot, wound, rain, place, route and close timing.
The synthesis leg at core scale remains what it is everywhere:
trusted tooling, cross-checked by the gl ladder booting both sides.

## Cycle 29 (2026-08-21): the chain closes, and the grounds are counted

The custody chain had one unproven hop left: the flow itself. Now
the netlist extracted from the CONFIRMED layout is formally
equivalent to the stitched netlist that entered it - 6915 points,
6632 by induction, six minutes forty-eight. The match needed no new
bookkeeping: the rails both netlists carry by name are the points,
the macros are cut to the boundary as before, and the clock tree
and thirty-two repair buffers evaporate inside the proof, because a
buffer is an assign to the equivalence library and an assign is a
wire. One pin taught one lesson: the write-port's A_DOUT hangs
unread, some writers list it and some omit it, and the cut now
skips dangling outputs on both sides rather than let a port nobody
drives break the matching. RTL to gates, gates to stitched,
stitched to placed-and-routed: every hop is now a theorem, and what
remains trusted is what every flow trusts - the tools that check,
checking themselves.

And the grounds are counted before the padframe exists to hold
them: from the measured 20.3 mA cluster and its 3.54 mV worst IR
drop, a planning bound of 40-60 mA for the die, four core pairs
for distribution, one array pair for the retention experiment, and
seven VDDIO/VSSIO pairs from the SSO rule applied to the 56 GPIO -
about twelve grounds against seventy-four signals, one to six,
conservative against the one-to-eight rule. Ninety-eight pads: an
LQFP-100/128-class frame, and if the OpenMPW slot cannot carry it,
PORTB is the knob that scales - never the ground ratio.

## Cycle 30 (2026-08-21): twenty-four timers, zero new pads

The last peripheral class where the yardstick simply had more chip:
24 configurable counter/timers against none. Slot 7 - the die's
final bus slot, the watchdog's last unpopulated haunt - now carries
the bank: 32-bit down-count with sticky overflow, PWM against a
compare, capture of a free-runner on a synchronized pin edge, pulse
counting, and VORAGO's own pin philosophy - the timers ride PORTB
as alternate functions, a leased pin is a timer's pin, and the pad
budget never hears about it. Every register is TMR'd, the running
counters included, because a flipped counter bit is a wrong period
and a flipped compare bit is a wrong duty forever; 9938 flops say
the discipline was not negotiated. And a wire that waited sixteen
cycles finally carries meaning: timer 0's overflow is the core's
timer interrupt - masked by RISC-V default until software asks,
capability without risk. An ISP-loaded program leases pin 5,
programs thirty percent, and the bench measures thirty percent on
the pin. The interface ledger against the VA10805 now reads: GPIO
matched, timers matched, debug ahead, telemetry ahead - and I2C,
general SPI and the second UART remain, named and priced.

## Cycle 31 (2026-08-21): two masters, one lesson per boundary

The I2C column closes. Two byte-command masters live in slot 6's
upper half - the address space the GPIO block never used, split by
one bit - and lease PORTA's low pins through the same alternate-
function discipline the timers set: an enabled controller's pins
are its pins, open-drain, pull-means-low, and the wire is read as
it actually is. A slave that stretches the clock is obeyed, not
fought - the master waits for the released wire to really rise,
which is the difference between a controller that works in a
datasheet and one that works on a bus. Every register down to the
engine state is TMR'd: a wedged peripheral FSM in flight is a lost
instrument.

Each boundary taught once. The bench slave served its read byte one
clock late and the master faithfully read the shift; the fix put
bit seven on the wire the moment the ack released. The stretch
counter counted edges on a wire it was itself holding still; time,
not edges. And the through-the-die program wrote its registers into
the MBIST doorway for one whole debugging session because 0x800 as
an addi immediate is NEGATIVE - the sign bit of a 12-bit constant,
the oldest RISC-V lesson there is, now paid for and recorded. The
interface ledger reads: GPIO matched, timers matched, I2C matched;
general SPI and the second UART remain, named and priced.

## Cycle 32 (2026-08-21): three masters and the edges that matter

The SPI column closes at the yardstick's count. Three full-duplex
masters take slot 7's upper half through the same one-bit split the
I2C pair proved, and lease PORTA's next twelve pins - SCK, MOSI and
CS driven, MISO listening - under the discipline that is now house
style: an enabled controller's pins are its pins. All four clock
modes, and a chip select that belongs to SOFTWARE, because auto-CS
is a guess about a protocol the controller cannot know.

The cycle's lessons were all about edges. MOSI must advance on the
NON-sampling edge - a wire that moves when the slave looks races
every device on the bus - so the out bit got its own register. The
idle clock IS the polarity, so a CPOL change reaches the pin before
the next arm, not after. And two bench-side truths: a slave is deaf
while deselected, and configure-then-select is not etiquette but
correctness - flipping CPOL in the write that asserts CS hands the
slave a config edge dressed as data. The through-the-die program
paid nothing at all: the addi sign lesson from the I2C cycle built
0x7800 correctly on the first try. One interface column remains:
the second UART, named and priced.
