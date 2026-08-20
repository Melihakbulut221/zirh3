# ZIRH-3 - one command per proof class
#
#   make units      six block suites (cocotb + iverilog)
#   make sv         SV boot-scenario suite
#   make formal     yosys-smtbmc + z3 proofs
#   make tmr        synthesis-integrity (replicas survive)
#   make lint       verilator, warning-clean policy
#   make trace      requirements <-> tests, no orphans
#   make dft        F28: boundary scan bench + scan-insertion rehearsal
#   make gl         Cycle 19: TMR'd core boots at gate level, wounded + healed
#   make gldie      Cycle 25: the WHOLE die on gates boots, wounded + rained-on
#   make fuzz       Cycle 26: the traffic storm at the pins (seeded)
#   make equiv      Cycle 28: RTL-vs-stitched formal equivalence (both legs)
#   make everything

.PHONY: units sv formal tmr lint trace dft gl gldie fuzz equiv everything

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
	$(MAKE) -C test -B -f Makefile.gpio

sv:
	$(MAKE) -C test -f Makefile.svs boot
	$(MAKE) -C test -f Makefile.svs fuzz

dft:
	$(MAKE) -C test -B -f Makefile.bscan
	bash scripts/dft_scan.sh

gl:
	bash scripts/gl_boot.sh all

gldie:
	bash scripts/gl_die.sh all

fuzz:
	$(MAKE) -C test -B -f Makefile.top COCOTB_TEST_MODULES=test_top_fuzz

equiv:
	bash scripts/formal_equiv.sh all

formal:
	bash scripts/formal.sh

tmr:
	bash scripts/check_tmr.sh

lint:
	bash scripts/lint.sh

trace:
	python3 scripts/trace_check.py

everything: lint trace tmr units sv dft gl gldie fuzz formal equiv
