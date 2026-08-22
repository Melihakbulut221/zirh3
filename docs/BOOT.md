# The boot contract

Three RTL files have cited this document as their contract since the
loader was written - `zirh_boot_ctrl.v` twice, for the protocol and
for the fault model, and `zirh_qspi.v` once, for where sector-level
CRC belongs. The document did not exist. An audit found the dangling
citation in Cycle 39 and Cycle 45 writes it, derived from the code
rather than from memory: every field, bound and verdict below was
read out of `src/zirh_boot_ctrl.v` and the encoder in
`test/test_top_isp.py`, which is the reference implementation the
suites use.

## The image

An image is a twelve-byte header followed by the payload. Every
multi-byte field is little-endian, and the payload is a whole number
of 32-bit words, each little-endian.

| offset | size | field | meaning |
|---|---|---|---|
| 0 | 4 | magic | `0x5A495248` - the ASCII bytes `HRIZ` on the wire |
| 4 | 2 | length | payload size in WORDS |
| 6 | 2 | version | gates the ROLLBACK floor since Cycle 47 - see below |
| 8 | 4 | crc32 | over the payload bytes only, header excluded |
| 12 | 4 x length | payload | the program, word by word |

The CRC is the ordinary IEEE 802.3 reflected CRC-32 with all-ones
initial and final values - `zlib.crc32` of the payload bytes, with no
further transformation.

A header is accepted when the magic matches, the length is non-zero,
the length fits the bank with three words to spare, and the version
clears the rollback floor. Anything else is a refusal, decided the
moment the twelfth header byte lands: a loader that started writing
before it believed the header would have to un-write it.

## The rollback floor

The loader holds a monotonic version floor in the same POR-domain
TMR state as the bank bookkeeping. An image whose version is BELOW
the floor is refused at the header, before a single payload byte is
taken; an image at or above it may proceed, and an ACCEPT raises the
floor to the accepted version. Equal is allowed on purpose -
re-flashing the version you already run is maintenance, and a floor
that forbids it forces every re-flash to lie about its version.

Three edges of the law, each deliberate:

- the floor survives a watchdog reset, like the rest of the
  bookkeeping - one starved boot must not reopen the door.
- the REVERT ladder is policy-free. A watchdog failure falls to the
  other valid bank whatever its version, because survival outranks
  rollback: a die that refuses its only working image on principle
  is not protected, it is dead.
- the floor resets at power-on. That is the experiment-class subset:
  true anti-rollback needs state that survives power, which this
  open PDK cannot fuse - the product part seeds the floor from the
  MRAM config page (the same architectural equivalent SCOPE records
  for eFuse), and the loader logic is identical either way.

These are theorems, not intentions: the floor never falls, and
nothing below it ever commits - proven by the same unbounded
induction as the ruling laws, with reachability covers showing a
genuine rise and a genuine version refusal.

## The transport

The loader consumes a byte stream over a valid/ready handshake and
nothing else. That is the whole reason the same controller boots from
a UART on the ground and from external MRAM in flight (Cycle 38): the
transport is swappable because the contract is a byte at a time.

The handshake means what it says. A byte is consumed on the clock edge
where the sender holds valid AND the loader raises ready; if ready is
low, the byte has NOT been taken and the sender must keep offering it.
This matters in exactly one place, and it cost a cycle to learn: in
host mode a byte arriving while the die is running WAKES the loader,
moving it from RUN into header collection. The loader raises no ready
in RUN, so that byte is not consumed - a sender that honours the
handshake re-offers it and it becomes header byte zero. A sender that
assumes ready is steady loses it, and every host-mode reload is then
refused for a bad magic that was never bad (Cycle 44).

Silences are free. The loader holds its place between bytes for as
long as the sender needs.

## The straps

Sampled once, out of reset:

| strap | meaning |
|---|---|
| `00` | golden - run the mask ROM, load nothing |
| `01` | load bank A |
| `10` | load bank B |
| `11` | host - load the inactive bank, and accept a fresh image later |

## The ruling

At the flight straps (`00`, `01`, `10`) the loader rules ONCE per
reset. It collects a header, streams the payload into the target
bank, reads the stored image back and judges it, and then it is done:
it holds no bus, raises no ready, and cannot re-enter the load path
until the next power-on reset. Those are theorems, not intentions -
`formal/f_boot.sv` proves them by unbounded induction over free
inputs (Cycle 39).

**Accept** marks the target bank valid, clears its suspect bit, points
the preference and the fetch mux at it, and runs.

**Refuse** falls back: the OTHER bank if it is valid and not suspect,
otherwise the golden ROM. Golden is absorbing - one clock inside it
and the die stays there with the fetch mux on ROM, whatever arrives
afterwards.

Host mode is the exception, by design. There the loader accepts a
fresh image while the die keeps running, always staging it into the
INACTIVE bank so the code under the CPU's feet is never the code being
overwritten.

## The fault model

The stream is transport; the STORED image is the truth. The CRC the
loader checks is computed over the words read BACK out of the bank
through the SECDED-corrected port, not over the bytes as they arrived.
A stream corrupted in flight, a write that landed wrong, a cell that
lied - all three fail the same check, because the question asked is
"is what I stored what was meant?" rather than "did I hear correctly?"

A bank's valid flag therefore rises only out of verification. That is
also a theorem: no interrupted, truncated or hostile stream can leave
a bank looking bootable.

The signature verdict (`sig_ok_i`) is a second, independent gate on
the same decision - an image with a perfect CRC is still refused if
the signature says no. On this experiment class it is tied true and
the CRC carries the decision alone; the port exists so a product die
can put a real verifier behind it without touching the loader.

## After the ruling: the revert ladder

A committed bank must prove itself. Firmware signs on by writing the
telemetry signature; the housekeeping watchdog reports a bank that
never did.

On a watchdog failure the running bank is marked suspect and the die
falls to the other valid bank, or to golden if there is none. A
sign-on clears the running bank's suspect mark - but never in the same
cycle a watchdog failure sets it. That last clause is not fussiness:
without it a sign-on landing on the failure edge erased the evidence
the watchdog had just written, and a starving die swapped between two
banks forever instead of reaching the mask ROM (Cycle 39). It is a
theorem now.

## What layers above this

Sector-level CRC for an in-flight updater is NOT part of this
contract. The loader judges whole images; an updater that rewrites
external MRAM a sector at a time needs its own per-sector integrity,
and that belongs in the protocol above both the loader and the QSPI
reader rather than duplicated inside either. `zirh_qspi.v` says so at
its own front door, and this is the document it defers to.

## Honest limits

- The rollback floor resets at power-on; the product part seeds it
  from the MRAM config page. Within a session it is a theorem.
- `sig_ok_i` is hardwired true in both instantiations on this die.
- The bound on length is the bank's size less three words; there is
  no separate minimum beyond non-zero.
