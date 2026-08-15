# ZIRH-3 - one command per proof class
#
#   make units      six block suites (cocotb + iverilog)
#   make sv         SV boot-scenario suite
#   make formal     yosys-smtbmc + z3 proofs
#   make tmr        synthesis-integrity (replicas survive)
#   make lint       verilator, warning-clean policy
#   make trace      requirements <-> tests, no orphans
#   make dft        F28: boundary scan bench + scan-insertion rehearsal
#   make everything

.PHONY: units sv formal tmr lint trace dft everything

units:
	$(MAKE) -C test -B -f Makefile.boot
	$(MAKE) -C test -B -f Makefile.qspi
	$(MAKE) -C test -B -f Makefile.clkobs
	$(MAKE) -C test -B -f Makefile.dbg
	$(MAKE) -C test -B -f Makefile.sram39
	$(MAKE) -C test -B -f Makefile.bist
	$(MAKE) -C test -B -f Makefile.memsys
	$(MAKE) -C test -B -f Makefile.porro
	$(MAKE) -C test -B -f Makefile.die
	$(MAKE) -C test -B -f Makefile.sramdut
	$(MAKE) -C test -B -f Makefile.jtag

sv:
	$(MAKE) -C test -f Makefile.svs boot

dft:
	$(MAKE) -C test -B -f Makefile.bscan
	bash scripts/dft_scan.sh

formal:
	bash scripts/formal.sh

tmr:
	bash scripts/check_tmr.sh

lint:
	bash scripts/lint.sh

trace:
	python3 scripts/trace_check.py

everything: lint trace tmr units sv dft formal
