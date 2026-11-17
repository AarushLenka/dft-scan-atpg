SHELL := /bin/bash

GENUS       ?= genus
MODUS       ?= modus
MODUS_FLAGS ?= -files run_atpg.tcl
CHAINS      ?= 1

.PHONY: all sim lint tclcheck flops baseline dft atpg sweep results selftest clean

all: sim lint tclcheck

## ---------------------------------------------------------------- no Cadence
## Everything below runs with open-source tools only.

# Self-checking loopback simulation of the RTL.
sim:
	cd rtl && iverilog -g2012 -o tb_top.vvp tb_top.v top.v && vvp tb_top.vvp

# Static lint. Must be silent.
lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTH \
	          --top-module top rtl/top.v

# Parse-check the Cadence Tcl scripts (vendor commands stubbed out).
tclcheck:
	bash scripts/check_tcl.sh

# Pre-synthesis flop count (approximates "N-flop design" for the README).
flops:
	@yosys -p "read_verilog rtl/top.v; hierarchy -top top; proc; memory_map; flatten; opt -fast; stat -width" 2>/dev/null \
	  | awk '/=== top ===/,0' | grep -E 'dff|DFF' || true

## ---------------------------------------------------------------- Genus side
## Needs: Genus on PATH, lib/cells.lib, lib/cells.v present.
## Run from a server session; each chain count writes p2_scan/runs/c<N>/.

baseline:
	mkdir -p p2_scan/runs/baseline
	cd p2_scan && $(GENUS) -f baseline.tcl -log runs/baseline/baseline.log

dft:
	mkdir -p p2_scan/runs/c$(CHAINS)
	cd p2_scan && DFT_CHAINS=$(CHAINS) $(GENUS) -f dft.tcl -log runs/c$(CHAINS)/dft.log
# Genus 21.14 writes its Modus hand-off into p2_scan/test_scripts/ (older
# releases drop top_atpg*/ *.atpg / *.pinassign in the CWD), so sweep all of
# them into the run directory to keep one run's outputs together.
	@shopt -s nullglob; \
	for f in p2_scan/top_atpg* p2_scan/*.atpg p2_scan/*.pinassign \
	         p2_scan/test_scripts; do \
	  if [ -e "$$f" ]; then \
	    mv "$$f" p2_scan/runs/c$(CHAINS)/ && \
	    echo "moved $$f -> p2_scan/runs/c$(CHAINS)/"; \
	  fi; \
	done; true

## ---------------------------------------------------------------- Modus side

atpg:
	@if [ ! -f p2_scan/runs/c$(CHAINS)/top_scan.v ]; then \
	  echo "missing p2_scan/runs/c$(CHAINS)/top_scan.v -- run 'make dft CHAINS=$(CHAINS)' first"; \
	  exit 1; \
	fi
# Modus does not reliably write a log file of its own, so tee one next to the
# run. pipefail keeps grep-able output and the real exit status.
	mkdir -p p2_atpg/runs/c$(CHAINS)
	set -o pipefail; cd p2_atpg && \
	  DFT_CHAINS=$(CHAINS) $(MODUS) $(MODUS_FLAGS) 2>&1 \
	  | tee runs/c$(CHAINS)/atpg.log

## ---------------------------------------------------------------- reporting

sweep:
	bash scripts/sweep_chains.sh

results:
	python3 scripts/collect_results.py

selftest:
	python3 scripts/collect_results.py --selftest

clean:
	rm -rf rtl/tb_top.vvp rtl/tb_top.vcd p2_scan/runs p2_atpg/runs \
	       results_table.md results_table.csv
