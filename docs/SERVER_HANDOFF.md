# Running this project on the SSH server (Genus + Modus)

Everything that can be done without Cadence is already done and verified:
the DUT, the testbench, the constraints, the Genus and Modus scripts, the
chain sweep, and the results collector. This file is the checklist for the part
that needs the licensed tools.

Time on the server: ~2 hours for the first pass (most of it is fixing the pin
assignment file and reading DRC reports), ~20 minutes for the 4-chain sweep.

---

## 0. Prep the server session

If `echo $0` says `csh` or `tcsh` (common on university servers), run `bash`
first — the examples below use bash syntax (`export X=1`, `2>&1`) that csh
rejects. The `make` targets themselves always run under bash.

```bash
# whatever your site uses for the tool environment / licence
module load genus modus           # or: source ~/cadence/setup.csh
which genus modus                 # both must resolve
```

Clone the repo somewhere convenient, alongside your other DFT projects:

```bash
mkdir -p ~/dft_projects && cd ~/dft_projects
git clone <repo-url> dft-scan-atpg     # or scp/rsync it from your laptop
cd dft-scan-atpg
```

## 1. Point the flow at a real cell library  ← the blocking step

`lib/cells.lib` and `lib/cells.v` are not in the repo (they are licensed PDK
files). Find them on the server and link them:

```bash
find / -name "*.lib" -path "*lib*" 2>/dev/null | head        # find candidates
ln -sf /path/to/kit/cells.lib lib/cells.lib
ln -sf /path/to/kit/cells.v   lib/cells.v
```

Then confirm the kit can actually do full scan — this is the single most common
reason the whole project stalls:

```bash
grep -ci "sdf" lib/cells.lib        # > 0 means scan flops exist (SDFF/D/SDF...)
grep -ci "sdf" lib/cells.v
```

If both files must come from different paths, that is fine, but they must
describe the **same** cells, or Modus `build_model` and gate-level sim will
disagree with the netlist.

> If the kit only has `.db` (Synopsys) files: convert with `lc_shell`
> (`read_db ...; write_lib -format Liberty ...`) or find the Liberty original.

## 2. Re-run the free checks on the server

They should still pass; if they don't, the clone is broken, not the PDK.

```bash
make sim        # PASS: all checks passed
make lint       # silent
make tclcheck   # 5× ok
```

## 3. Baseline synthesis (the "before" area)

```bash
make baseline            # or: cd p2_scan && genus -f baseline.tcl -log runs/baseline/baseline.log
```

Produces `p2_scan/runs/baseline/`:

| File | What to look at |
|---|---|
| `baseline_area.rpt` | total cell area — the divisor in the overhead calculation |
| `baseline_timing.rpt` | WNS should be small and positive at 10 ns |
| `kpi.txt` | `AREA_CELL` / `NUM_FLIPFLOPS` for the results table |

Check `kpi.txt` — if `AREA_CELL NA`, every attribute spelling in
`p2_scan/kpi.tcl` was rejected (current Genus wants `design:/top`, older builds
want `design:top`) and the report was not parseable; read the number off
`baseline_area.rpt` and paste it into `kpi.txt` by hand. The flow does not
depend on the attribute: `kpi.tcl` already falls back to scraping
`Total cell area:` out of the report, so `NA` here means both paths missed and
is worth a look.

## 4. Scan insertion

```bash
make dft CHAINS=1
```

Produces `p2_scan/runs/c1/`. Read these in order:

1. **`dft_rules_pre.rpt`** — pre-scan DRC. Expect no *errors*. Warnings about
   untestable/uncontrollable points are the interesting part and are what
   Project 5 is about.
2. **`dft_rules_post.rpt`** — post-scan DRC. Must be clean; anything here shows
   up as a failure in Modus `verify_test_structures`.
3. **`scan_chains.rpt`** — number of chains, flops per chain, **and the exact
   SI/SO/SE port names**. This file is the authority for the next step.
4. **`scan_setup.rpt`** — scan style, chain count, SE definition.
5. **`top_scan.v`** — grep for your library's scan flop (`grep -c SDFF
   top_scan.v`). Flop count should equal `baseline` flops. If it is zero,
   `syn_map` ran before the scan style took effect, or the library has no scan
   flops.
6. **`dft_area.rpt`** — compare to baseline for the overhead number.

Also written into `runs/c1/`: whatever `write_dft_atpg` generated (pin
assignment file / run script). The Makefile moves it there from `p2_scan/`.

**Do not skip this:** the `dft_area` number and the `kpi.txt` from this run are
what the results table uses.

## 5. Fix up the pin assignment file, then run Modus

```bash
cd p2_atpg
```

Step 5a — get a correct pinassign. Options, in order of preference:

1. Use the file `write_dft_atpg` generated (already moved into
   `p2_scan/runs/c1/test_scripts/`). It is the real syntax for your Modus
   version; `p2_atpg/top.pinassign` is already a copy of it for 1 chain.
2. For CHAINS>1 nothing to do by hand: `p2_atpg/run_atpg.tcl` generates
   `runs/c<N>/top.pinassign` from `DFT_CHAINS`, one `dft_sdi_<i>/SI<i-1>` and
   `dft_sdo_<i>/SO<i-1>` pair per chain. Port suffix 1-based, channel 0-based.
   Cross-check against `scan_chains.rpt` (names) and the `top_scan.v` header.

Step 5b — run:

```bash
mkdir -p runs/c1
DFT_CHAINS=1 modus -legacy_ui -files run_atpg.tcl     # adjust flags for your release
# or from the repo root:
make atpg CHAINS=1 MODUS_FLAGS='-files run_atpg.tcl'
```

If the CLI flags are wrong, `modus -help` / `modus -files run_atpg.tcl`, or start
`modus` interactively and paste the commands from `run_atpg.tcl` one at a time.
The script is plain Modus commands — it is not tied to the wrapper.

**Order of failure-fixing:**

1. `build_model` — "cell not found" means `lib/cells.v` is missing a scan flop
   model; "module not found" means `-allowmissingmodules yes` needs the missing
   module supplied instead.
2. `build_testmode` — almost always a pinassign name mismatch.
3. `verify_test_structures` — chain shift errors mean `SE` is not constant-high
   during shift, or `rst_n` is active during shift. Fix the pinassign, not the
   netlist.
4. `create_logic_tests` — only now do coverage numbers mean anything.

## 6. Record the numbers

Modus prints the fault summary at the end of `create_logic_tests` / in the run
log. Fill `p2_atpg/runs/c1/atpg_kpi.txt` (the collector creates it on first run
with a template):

```
LONGEST_CHAIN       <flops per chain from scan_chains.rpt>
PATTERNS            <number of committed patterns>
TEST_COVERAGE       <test coverage %, digits only>
TOTAL_FAULTS        <total stuck-at faults>
DETECTED_FAULTS     <detected>
UNTESTABLE_FAULTS   <ATPG-untestable>
ATPG_RUNTIME        <seconds>
```

Coverage definition Modus reports:
`test_coverage = detected / (total_faults − untestable_faults)`.
If you report a different denominator, say so in the README — interviewers do
ask.

## 7. The chain-count experiment (deliverable table)

```bash
bash scripts/sweep_chains.sh 1 2 4 8
```

That re-runs Genus and Modus per chain count into separate `runs/c<N>/`
directories; a failed ATPG run keeps its netlist and the sweep continues with
the next chain count. At the end it rebuilds `results_table.md` / `.csv`.
Fill each `p2_atpg/runs/c<N>/atpg_kpi.txt` as you go, then `make results` again.

## 8. Gate-level verification of the patterns (step 5 of the guide)

This is the step that turns "ATPG said 97%" into "the patterns actually work".

1. Use the `top_vec.v` written by `write_vectors` plus
   `p2_scan/runs/c1/top_scan.v` and `lib/cells.v`.
2. `rtl/tb_top.v` is the starting point: it already drives `clk`, `rst_n`,
   `baud_div` and both FIFO interfaces, and checks received bytes. For vector
   replay you need a `tb_gls.v` that instantiates the netlist plus the vector
   module and compares the netlist's output pins against the vector module's
   expected outputs every cycle. The vector file's port list (open
   `top_vec.v` and look at its module header) decides the exact stimulus, which
   is why this testbench cannot be written before the first ATPG run.

```bash
cd ~/dft_projects/dft-scan-atpg
iverilog -g2012 -o p2_atpg/runs/c1/gls.vvp \
    p2_scan/runs/c1/top_scan.v lib/cells.v \
    p2_atpg/runs/c1/top_vec.v p2_atpg/tb_gls.v
cd p2_atpg/runs/c1 && vvp gls.vvp
```

   or, on Xcelium (from the repo root):

```bash
xrun -64bit -access +rwc -elaborate \
     p2_scan/runs/c1/top_scan.v lib/cells.v \
     p2_atpg/runs/c1/top_vec.v p2_atpg/tb_gls.v
```

3. Expect **zero** mismatches on the pattern outputs. Two known X-noise sources
   before you chase a bug:
   - the FIFO array flops have no reset, so they are X until written; if the
     first patterns disagree only on `rd_data`, that is X-propagation, not a
     broken pattern;
   - the `rx` input is X in vector mode unless the pinassign ties it or the
     vector file drives it — check that it is not feeding the RX FSM X states
     into the scan chains.

## 9. What to commit back

```bash
mkdir -p report
cp p2_scan/runs/baseline/{baseline_area.rpt,baseline_timing.rpt} report/
cp p2_scan/runs/c1/{dft_rules_pre.rpt,dft_rules_post.rpt,scan_setup.rpt,scan_chains.rpt,dft_area.rpt} report/
cp p2_atpg/runs/c1/top.pinassign report/
cp results_table.md results_table.csv report/
git add report results_table* README.md
```

Then update the README: paste `results_table.md` into the Results section,
replace the `<N>/<K>/<X>/<Y>/<P>` placeholders in the resume bullets, and note
anything your tool versions surprised you with (that is exactly the kind of
detail an interviewer trusts).

## Version-sensitivity cheat sheet

These are the points where your Genus/Modus release may want different syntax.
Each is a one-line edit; none of them change the design or the methodology.

| Script | Line | If it fails, try |
|---|---|---|
| `p2_scan/dft.tcl` | `set_db dft_scan_style muxed_scan` | `set_db / .dft_scan_style muxed_scan` |
| `p2_scan/dft.tcl` | `define_shift_enable -name SE ...` | `create_test_protocol`/`set_db dft_shift_enable_port` per your version's DRC |
| `p2_scan/dft.tcl` | `set_db design:top .dft_min_number_of_scan_chains` | `set_db design:/top .dft_min_number_of_scan_chains` (note the slash; `TUI-182 <Start> word is not recognized` means the path spelling is wrong for your release) |
| `p2_scan/dft.tcl` | `write_dft_atpg -library ../lib/cells.v` | `write_dft_atpg` (no `-library`), then point Modus at `cells.v` yourself |
| `baseline.tcl` / `dft.tcl` | `report_area > $::OUT/...` | `report_area -output $::OUT/...` |
| `p2_scan/*.tcl` | `genus -f script.tcl` | `genus -files script.tcl` |
| `p2_atpg/run_atpg.tcl` | `modus -legacy_ui -files ...` | `modus -files ...`, or paste commands into an interactive session |
| `p2_scan/top.sdc` | `remove_from_collection` | `[all_inputs] - [get_ports clk]` becomes `[remove_from_collection [all_inputs] [get_ports clk]]` or just `[all_inputs]` |
