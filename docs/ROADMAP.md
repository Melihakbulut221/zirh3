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
