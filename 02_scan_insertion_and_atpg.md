# Project 2: Full-Scan Insertion (Genus) + Stuck-At ATPG (Modus)

**Time:** 5-7 hours | **Tools:** Genus + Modus | **Difficulty:** Beginner-Intermediate
**This is the flagship project.** Projects 3, 4 and 5 all reuse its output.

## What you will build
You take a normal sequential design (flip-flops, clocks, resets), then:
1. Synthesize it with **Genus**.
2. **Insert scan chains** so every flop becomes controllable and observable.
3. Run **DFT rule checks**.
4. Hand it to **Modus** to generate stuck-at test patterns.
5. Report coverage, pattern count and scan overhead (area cost of DFT).

This is the complete "RTL to manufacturing test patterns" story, which is exactly what DFT interviewers ask about.

## Why scan exists (read this once)
Testing a sequential circuit through its normal pins is nearly impossible because internal flop states are hidden. Scan replaces each flop with a **scan flop** (a flop plus a 2:1 mux):
- `SE=0`: normal operation (flop takes D from the logic)
- `SE=1`: shift mode (flop takes its value from the previous flop, forming a long shift register)

Test procedure per pattern: shift in values (SE=1) -> apply one capture clock (SE=0) -> shift out the response while shifting in the next pattern. ATPG then only deals with *combinational* logic between flops, which is a solved problem.

## Pick your design
| Option | Size | Notes |
|--------|------|-------|
| ISCAS'89 **s5378** or **s9234** | ~200 flops | Safe first choice, small |
| ISCAS'89 **s38417** | ~1.6k flops | Great numbers, still fast |
| Your own **UART / FIFO / SPI** RTL | small | Looks more original on a resume |
| **PicoRV32** (RISC-V) | big | Best resume value, more DRC debug; do it only if you have time |

The rest of this guide uses a design called `top` with clock `clk` and active-low reset `rst_n`. Replace names with yours.

## Step 0: Folders and files
```bash
cd ~/dft_projects
mkdir -p p2_scan p2_atpg
# rtl/top.v          your design
# lib/cells.lib      Liberty file (for Genus)
# lib/cells.v        Verilog cell models (for Modus)
```

Create a constraints file `p2_scan/top.sdc`:
```tcl
create_clock -name clk -period 10 [get_ports clk]
set_input_delay 2 -clock clk [all_inputs]
set_output_delay 2 -clock clk [all_outputs]
```
(The period does not matter much for this project. Just do not make it absurdly tight.)

## Step 1: Baseline synthesis (no DFT yet) with Genus
You need a **before** area number to measure scan overhead later.

Create `p2_scan/baseline.tcl`:
```tcl
set_db init_lib_search_path ../lib
set_db library cells.lib
read_hdl ../rtl/top.v
elaborate top
read_sdc top.sdc
set_db syn_generic_effort medium
set_db syn_map_effort medium
syn_generic
syn_map
syn_opt
report_area  > baseline_area.rpt
report_timing > baseline_timing.rpt
write_hdl > top_nodft.v
exit
```
Run:
```bash
cd ~/dft_projects/p2_scan
genus -f baseline.tcl -log baseline.log
```
Write down the **total cell area** from `baseline_area.rpt`.

## Step 2: Synthesis with scan insertion
Create `p2_scan/dft.tcl`:
```tcl
set_db init_lib_search_path ../lib
set_db library cells.lib
read_hdl ../rtl/top.v
elaborate top
read_sdc top.sdc

# ---- DFT configuration ----
set_db dft_scan_style muxed_scan
set_db dft_prefix dft_
define_shift_enable -name SE -active high -create_port SE
# If your design has an async reset that must be held inactive during test,
# use define_test_mode to add a test-mode pin (verify command name in your version).

check_dft_rules > dft_rules_pre.rpt

# ---- Synthesis (scan-mapped) ----
set_db syn_generic_effort medium
set_db syn_map_effort medium
syn_generic
syn_map

# ---- Scan chain creation ----
# Try 1 chain first. Later, increase for shorter shift length.
set_db design:top .dft_min_number_of_scan_chains 1
connect_scan_chains -auto_create_chains -preview   ;# preview only
connect_scan_chains -auto_create_chains
syn_opt -incr

report_scan_setup  > scan_setup.rpt
report_scan_chains > scan_chains.rpt
check_dft_rules    > dft_rules_post.rpt
report_area        > dft_area.rpt
report_timing      > dft_timing.rpt

# ---- Outputs ----
write_hdl > top_scan.v
write_sdc > top_scan.sdc
write_dft_atpg -library ../lib/cells.v   ;# generates Modus-ready files
exit
```
Run:
```bash
genus -f dft.tcl -log dft.log
```

### What to check
1. `dft_rules_pre.rpt`: lists DFT violations (uncontrollable clock/reset, latches, etc.). A clean pass is ideal. If you see violations, read Project 5.
2. `scan_chains.rpt`: confirms number of chains, flops per chain, SI/SO port names.
3. `top_scan.v`: open it, search for `SDFF` (or whatever your library's scan flop is named) to see scan cells.
4. `write_dft_atpg` output: it should create a folder or files containing Modus input (a pin assignment file and a run script). **Look at what it generated; use those as your starting point.** This is the most reliable way to get the pin assignment file syntax right for your version.

### Compute scan overhead
```
Area overhead % = (dft_area - baseline_area) / baseline_area * 100
```
Typical full-scan overhead is a few percent to ~15% depending on design. Record yours.

## Step 3: Modus ATPG
Work in `~/dft_projects/p2_atpg`.

### 3a. The pin assignment file
This file tells Modus which pins are clocks, scan enable, scan in/out, and what constant values test pins take. If `write_dft_atpg` made one, copy it here. If you must write it yourself, it looks like this (verify syntax with the Modus docs for your version):

```
assign pin=clk      test_function=+TC;   # test clock
assign pin=SE       test_function=+SE;   # scan enable
assign pin=dft_si_0 test_function=+SI;   # scan in
assign pin=dft_so_0 test_function=-SO;   # scan out (confirm port names in scan_chains.rpt)
assign pin=rst_n    test_function=+TI;   # reset held inactive in test (value depends on polarity)
```
Port names must match what Genus created. Read them from `scan_chains.rpt`.

### 3b. Run the flow
```bash
build_model -designsource ../p2_scan/top_scan.v -designtop top -cell ../lib/cells.v -allowmissingmodules yes -workdir ./tbdata
build_testmode -testmode FULLSCAN -assignfile top.pinassign -modelname top -workdir ./tbdata
verify_test_structures -testmode FULLSCAN -workdir ./tbdata
build_faultmodel -fullfault yes -workdir ./tbdata
create_scanchain_tests -testmode FULLSCAN -experiment scan_exp -workdir ./tbdata
create_logic_tests -testmode FULLSCAN -experiment logic_exp -workdir ./tbdata
commit_tests -testmode FULLSCAN -inexperiment logic_exp -workdir ./tbdata
write_vectors -testmode FULLSCAN -inexperiment logic_exp -language verilog -outputfilename top_vec -workdir ./tbdata
```

### 3c. What each step is checking
- `verify_test_structures` (DRC): are all flops on scan chains? Are clocks and resets controllable? Does the chain shift correctly? **Fix any errors here before moving on.**
- `create_scanchain_tests`: a "chain test" (flush/shift test) proving the scan chains themselves work. If the chain is broken nothing else matters.
- `create_logic_tests`: the actual stuck-at ATPG.

### 3d. Collect results
From the logs/reports, record:
- Number of scan flops, number of chains, longest chain length
- Total faults, detected, untestable, test coverage %
- Number of patterns
- ATPG runtime

## Step 4: Experiment: number of chains
Shorter chains mean fewer shift cycles per pattern, so cheaper test. Change in `dft.tcl`:
```tcl
set_db design:top .dft_min_number_of_scan_chains 1    ;# then 2, 4, 8
```
Re-run Genus and Modus for each. Compute approximate test cycles:

```
test cycles ~= patterns x (longest chain length + 1)
```

| Chains | Longest chain | Patterns | Approx. test cycles | Coverage | Area overhead |
|--------|---------------|----------|---------------------|----------|---------------|
| 1 | | | | | |
| 2 | | | | | |
| 4 | | | | | |
| 8 | | | | | |

**Takeaway to state in your report:** more chains cut test time almost linearly but cost extra scan I/O pins. Pins are the real constraint, which motivates compression (Project 4).

## Step 5: Verify patterns by simulation (strongly recommended)
Use Modus's Verilog vector output with a simulator (Xcelium or other) against `top_scan.v` and the cell models. Zero mismatches proves your patterns are valid.

## Deliverables (put these on GitHub)
- `baseline.tcl`, `dft.tcl`, Modus run script
- Reports: DRC pre/post, scan chains, area before/after
- The results table
- A 1-2 page README with a block diagram: RTL -> Genus scan -> Modus ATPG -> patterns

## Resume bullets (use real numbers)
> - Implemented full-scan DFT on a <N>-flop <design> in Cadence Genus (muxed-scan, <K> chains), with <X>% area overhead.
> - Generated stuck-at ATPG patterns in Cadence Modus achieving <Y>% test coverage with <P> patterns; validated patterns via gate-level simulation.

## Troubleshooting
| Problem | Likely fix |
|---------|-----------|
| Genus: DFT rule violations on clock/reset | Clock or reset is generated internally; add test-mode override or mux (see Project 5) |
| Modus `build_testmode` fails | Pin names in assign file do not match netlist. Copy exact names from `scan_chains.rpt` |
| `verify_test_structures` chain-shift error | Scan enable not constant in shift, or reset active during shift |
| Low coverage (<90%) | Almost always a DRC/controllability issue; see Project 5 |
| Cell not found | `cells.v` missing the scan flop model; make sure the full library is passed |
