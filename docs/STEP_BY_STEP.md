# Step-by-step: running this on the server (assumes you know nothing)

You already rsync'd the folder to the server. This file is the exact order of
commands to type, what each one should print, and what to do when it doesn't.

Read it once, then work through it top to bottom. Do not skip ahead: step 2
(scan insertion) is useless if step 1 (the cell library) is not right, and it
will fail in a confusing way if you try.

Total time if nothing goes wrong: about 40 minutes.
Total time in reality, first attempt: 2–4 hours, almost all of it in step 4
and step 5.

---

## Contents

| Step | What | Needs Cadence? | Time |
|---|---|---|---|
| 0 | Get oriented in the shell | no | 5 min |
| 1 | Load the tools, check licences | no | 5 min |
| 2 | Point the flow at a real cell library | no | 20 min |
| 3 | Baseline synthesis (no DFT) | yes | 5 min |
| 4 | Scan insertion | yes | 10 min + fixing |
| 5 | Fix the pin assignment file | no | 10 min |
| 6 | ATPG | yes | 10 min + fixing |
| 7 | Record the numbers | no | 5 min |
| 8 | Chain-count sweep | yes | 30 min |
| 9 | Gate-level replay of the patterns | no | 30 min |
| 10 | Commit and fill in the README | no | 15 min |

---

## Step 0 — Get oriented

### 0.1 Go to the project

```bash
cd ~/dft_projects/dft-scan-atpg     # whatever path you rsync'd into
pwd
ls
```

You should see: `Makefile  README.md  docs  lib  p2_atpg  p2_scan  rtl  scripts`

If you see `top.v` and `tb_top.v` sitting loose instead of an `rtl` folder, you
are one directory too high — `cd` into wherever `Makefile` is:

```bash
find . -name Makefile -maxdepth 3
```

### 0.2 The four directories, in one sentence each

- `rtl/` — the Verilog design (`top.v`) and the simulation testbench (`tb_top.v`).
- `p2_scan/` — everything Genus (synthesis) needs: constraints `top.sdc`,
  `baseline.tcl`, `dft.tcl`, and `kpi.tcl` (shared helper that writes the
  machine-readable numbers). All its **output** lands in `p2_scan/runs/`.
- `p2_atpg/` — everything Modus (ATPG) needs: `run_atpg.tcl` and the pin
  assignment file `top.pinassign`. Output lands in `p2_atpg/runs/`.
- `lib/` — where the **PDK library** must appear (empty right now, on purpose).

### 0.3 Check your shell first — every command here assumes bash

```bash
echo $0        # bash -> all good; csh/tcsh -> read the next paragraph
```

Many university Cadence servers give you **`tcsh`/`csh`** as the login shell.
The commands in this guide use bash syntax (`export VAR=value`, `2>&1`,
`set -o pipefail`, `VAR=1 command`) and those fail in csh with confusing
messages such as "Variable name must begin with a letter" or "Ambiguous output
redirect". Start a bash shell once and stay in it:

```bash
bash
```

`make` is immune either way: every recipe runs under `/bin/bash` because the
Makefile starts with `SHELL := /bin/bash`. So the safest form of any step that
has a make target is just `make <target>`.

### 0.4 Three shell habits that will save you

```bash
less somefile.log          # read a file; q to quit, /word to search, n for next
grep -n "error" somefile   # find lines containing "error", with line numbers
tail -50 somefile.log      # last 50 lines — where the crash message always is
```

Also set up a scratch note file **now**; you will not remember the numbers:

```bash
$EDITOR notes.md           # or: nano notes.md
```

Whenever a step prints a number you care about (area, coverage, flop count),
paste it into `notes.md`. `p2_scan/runs/` gets wiped by `make clean`, your notes
do not.

---

## Step 1 — Load the tools and prove they run

```bash
module avail 2>&1 | grep -iE "genus|modus|cadence"
```

(or whatever your site uses — some sites want `source /tools/cadence/setup.csh`,
some already have it in your `.bashrc`. Ask your lab admin / the person who gave
you the account; this is the one step nobody can guess for you.)

```bash
module load genus modus          # names from the module avail output above
which genus modus
genus -version
modus -version
```

`which` must print two paths. If it prints nothing, the tools are not on your
`PATH` and **every** step below will fail with "command not found" — stop here
and fix the environment first.

### Licence check

Cadence tools fail *very* unhelpfully when there is no licence. The two
environment variables that matter:

```bash
echo $LM_LICENSE_FILE
echo $CDS_LIC_FILE
```

At least one should be non-empty and point at a licence server, e.g.
`5280@licsrv.your-uni.edu`. If both are empty, ask your admin for the licence
value and export it:

```bash
export LM_LICENSE_FILE=5280@licsrv.your-uni.edu     # example only
```

Then the cheapest possible licence test (30 s, no design needed):

```bash
echo "puts hello; exit" > /tmp/t.tcl
genus -f /tmp/t.tcl -log /tmp/t.log
```

If that prints a startup banner and `hello`, Genus has a licence.

### If you are in a queue / batch system

Some university servers only let you run Cadence through Slurm/PBS. In that
case put each command from this guide into a batch script and run it with
`sbatch`/`qsub` instead of directly. Everything else is identical; just remember
the tools take 1–2 minutes to start, so a "hung" job is usually just starting.

---

## Step 2 — Point the flow at a real cell library  ← the blocking step

**Why this matters.** `rtl/top.v` is written in plain Verilog. To turn it into
gates, Genus must be told which physical cells exist and how fast/area-heavy
they are. That data lives in a **Liberty file** (`.lib`, a text file). ATPG and
gate-level simulation additionally need the **Verilog models** of those same
cells (`.v`). Neither file can live in the git repo (licensed, tens of MB), so
the scripts expect them at exactly:

```
lib/cells.lib      <- Liberty timing/area
lib/cells.v        <- Verilog simulation models
```

### 2.1 Find the two files

Try these in order. The PDK on a university server is usually in `/pdk`,
`/tools`, `/cadence`, or somewhere in your home directory.

```bash
# a) environment variables the site may already have set for you
env | grep -iE "pdk|cds|tech|lib"

# b) obvious locations
ls /pdk 2>/dev/null
ls /tools 2>/dev/null
ls ~/pdk ~/libs 2>/dev/null

# c) brute force — Liberty files only, stop after 20 hits
find / -name "*.lib" -not -path "*/proc/*" 2>/dev/null | head -20
```

For the liberty file you are looking for something like
`.../libs/tcbn28hpcplusbwp30p140_tt0p9v25c.lib`, `.../slow.lib`,
`.../gpdk090/lib/gpdk090.lib`, or `sky130_fd_sc_hd__tt_025C_1v80.lib`.

> Use the **TT / typical** corner for the assignment. Corner choice changes
> area and timing by a few percent and does not matter for the DFT story; just
> say in the README which corner you used.

For the Verilog models:

```bash
find / -name "*.v" -path "*cell*" 2>/dev/null | head -20
find / -name "*.v" -path "*model*" 2>/dev/null | head -20
```

You are looking for a directory of one-file-per-cell models, or one big
`cells.v` / `_models.v`. If your kit ships a `.db` (Synopsys format) instead of
`.lib`, you cannot use it directly — find the `.lib` original, or convert it
with `lc_shell`:

```tcl
lc_shell
read_db your_cells.db
write_lib -format Liberty -output cells.lib your_lib_name
exit
```

### 2.2 Link them (do not copy — link)

```bash
cd ~/dft_projects/dft-scan-atpg
ln -sfn /absolute/path/to/kit/cells.lib lib/cells.lib
ln -sfn /absolute/path/to/kit/cells.v   lib/cells.v
ls -l lib/
```

`ls -l` must show two lines with `->` pointing at real files. **Use absolute
paths** — a relative symlink breaks the moment anything runs from a
subdirectory, and `p2_scan/*.tcl` runs from `p2_scan/`.

If you would rather not touch `lib/`, edit the one line `set_db library cells.lib`
in `p2_scan/baseline.tcl` and `p2_scan/dft.tcl` to name your file, and the
`-cell ../lib/cells.v` line in `p2_atpg/run_atpg.tcl`. Linking is less work.

### 2.3 Prove the library can do scan  ← do not skip this

```bash
grep -ci "sdf" lib/cells.lib      # count of scan-flop-ish cells, must be > 0
grep -ci "sdf" lib/cells.v
```

Both numbers must be greater than zero. The exact spelling depends on the kit:
`SDFF`, `SDFFR`, `SDFXT`, `sdfxtp_2`, `dfxtp` + scan — anything containing
`sdf` in the cell name means "flop with a scan enable pin", which is what scan
insertion needs.

- **`.lib` > 0 but `.v` = 0** → your Verilog models are elsewhere or the file is
  a stub. Find the real models; ATPG and gate-level sim will not work without
  them.
- **Both 0** → this kit has no scan flops, full scan is impossible with it. Ask
  your instructor/sysadmin for a kit with scan cells (any real standard-cell
  library has them; a "gpdk"/educational-only kit may not). Do not try to work
  around this by hand-instantiating muxes.
- Sanity check they are the *same* kit:

  ```bash
  grep -oiE "^cell *\([a-zA-Z0-9_]+" lib/cells.lib | head -5
  grep -oE "^module +[a-zA-Z0-9_]+" lib/cells.v | head -5
  ```

  The names must match. Mixing Liberty from kit A with Verilog from kit B is the
  single most common cause of later "cell not found" errors.

Write down in `notes.md`: kit name, corner, and whether `cells.v` is one file or
a directory (if a directory, see the note at the end of step 6).

### 2.4 One free sanity check before spending licences

Nothing here needs Cadence, and it catches typos in the design rather than in
the flow:

```bash
make sim        # expect: PASS: all checks passed
make lint       # expect: no output at all
make flops      # expect a list ending in 129 total flops
```

If `make sim` fails on the server but passed on your laptop, the rsync dropped
a file — re-rsync rather than debug the design.

---

## Step 3 — Baseline synthesis (the "before" number)

This is the design without any test logic. Its area is the denominator in the
scan-overhead percentage, so it must exist before anything else.

```bash
make baseline
```

What it does, literally: `cd p2_scan && genus -f baseline.tcl -log
runs/baseline/baseline.log`. Takes 1–3 minutes for a 129-flop design.

### 3.1 Check it actually finished

```bash
tail -20 p2_scan/runs/baseline/baseline.log
```

The two things that mean success: a total cell area report near the end, and no
line containing `Error` in the last screenful.

```bash
grep -iE "^ *error|fatal|cannot" p2_scan/runs/baseline/baseline.log | head
```

That should print nothing. Two lines that DO show up and are harmless:

```
Warning : Command 'commit_power_intent' cannot proceed as there is no power intent loaded. [CPI-506]
Error   : <Start> word is not recognized. [TUI-182] [get_db]
```

- **`commit_power_intent`** is Genus's built-in flow step wanting power intent
data (UPF) that this design does not have. It matched the grep only because the
word "cannot" appears in the warning text. Ignore it.
- **`TUI-182 [get_db]`** came from the old KPI query `get_db design:top .area`:
the CUI object path is spelled `design:/top` on current releases. It is caught
and the run continues, so it never hurt the netlist or the reports — but it did
leave `AREA_CELL` as `NA` in `kpi.txt`. `p2_scan/kpi.tcl` now tries
`design:/top`, then `get_db designs .area`, then reads the number straight out
of `baseline_area.rpt`, so re-running gives a real value.

If you see any *other* `Error` line, that one is real — read it.

### 3.2 Read the numbers

```bash
cat p2_scan/runs/baseline/kpi.txt
less p2_scan/runs/baseline/baseline_area.rpt
less p2_scan/runs/baseline/baseline_timing.rpt
```

- `kpi.txt` should show `AREA_CELL <number>` and `NUM_FLIPFLOPS 129`.
- `AREA_CELL NA` means your Genus version does not accept
  `get_db design:/top .area`. `kpi.tcl` already falls back to the report, so a
  remaining `NA` means both paths missed; open `baseline_area.rpt`, find the
  `Total cell area:` line, and paste the number into `kpi.txt` by hand:

  ```bash
  grep -i "total cell area" p2_scan/runs/baseline/baseline_area.rpt
  ```

  then edit the `AREA_CELL` line to that value. The script will then use it.
- `NUM_FLIPFLOPS` should be 129. If it is not 129, stop and understand why
  before continuing: your synthesis optimised some registers away, which means
  the RTL and the constraints disagree (usually a broken `set_load`/
  `set_input_delay` in `top.sdc`, or a library that is missing a cell type).
- `baseline_timing.rpt`: the slack (WNS) should be positive. At a 10 ns clock on
  a 129-flop UART it will be, comfortably. If it is negative, your library corner
  is very slow and you should switch to the TT corner.

If Genus died before writing `runs/baseline/`, go to the troubleshooting table
at the end of this file.

**Record in `notes.md`:** `baseline area = ______`, `baseline flops = 129`.

---

## Step 4 — Scan insertion (chains = 1 first)

```bash
make dft CHAINS=1
```

Takes 2–5 minutes. Output in `p2_scan/runs/c1/`. Start with one chain: fewer
chains means fewer names to get right in step 5, and it is the worst case for
test time, which makes a better story in the report.

### 4.1 Read the reports in this order

Do them one at a time and actually look at each. This order exists because each
file answers a question that the next file assumes.

**1. `dft_rules_pre.rpt` — DRC before scan insertion**

```bash
less p2_scan/runs/c1/dft_rules_pre.rpt
```

You want **zero errors**. Warnings about "uncontrollable"/"unobservable" points
are normal in a design with a FIFO and are the subject of the next project —
note how many there are, don't chase them.

Errors here mean the *design* violates a scan rule (typically: a register
without a reset on an async reset path, or a latch). You will have to change
`rtl/top.v` and re-run — but the DUT was written to be monotonous on purpose
(one clock, one async active-low reset, no gated clocks, no latches), so this
report should be clean. If it is not, read the offending message and fix the
RTL, not the script.

**2. `dft_rules_post.rpt` — DRC after scan stitching**

```bash
less p2_scan/runs/c1/dft_rules_post.rpt
```

This one must be clean, errors *and* ideally warnings. Anything here is a
fault that will re-appear as a failure in Modus `verify_test_structures` in
step 6, hours later. Fix it now.

**3. `scan_chains.rpt` — the authoritative list of ports**

```bash
less p2_scan/runs/c1/scan_chains.rpt
```

This is the most important file in the whole project. It tells you:

- how many chains were built (should be 1),
- how many flops are in the chain (should be 129, matching baseline),
- the **exact names** of the scan-in, scan-out and scan-enable ports.

The names are *whatever Genus decided*, not what we guessed. Copy them out:

```bash
grep -iE "scan|si|so|se|chain" p2_scan/runs/c1/scan_chains.rpt | head -40
```

**Record in `notes.md`:** chain count, flops per chain, and the exact SI / SO /
SE port names. You need these in step 5 and you will not want to re-find them.

**4. `scan_setup.rpt` — what configuration was used**

```bash
less p2_scan/runs/c1/scan_setup.rpt
```

Confirms: scan style `muxed_scan`, shift enable port `SE`, active high, prefix
`dft_`. If `SE` is missing here, `define_shift_enable` silently did nothing in
your Genus version — see the version table at the end.

**5. `top_scan.v` — the actual netlist**

```bash
grep -ciE "sdf" p2_scan/runs/c1/top_scan.v     # should be 129 (or close)
grep -c "^ *[A-Za-z_][A-Za-z0-9_]* *u" p2_scan/runs/c1/top_scan.v
```

If the scan-flop count is **0**, the library has no scan cells or `syn_map` ran
before the scan style took effect — go back to step 2.3 and then to the version
table. A netlist with no scan flops will make step 6 fail confusingly.

Open the top of the file and look at the module header:

```bash
head -40 p2_scan/runs/c1/top_scan.v
```

You should see the original ports plus `SE`, `dft_sdi_1` and `dft_sdo_1` (the
real names on Genus 21.14: the port suffix is 1-based). **This header is your
second source of truth for port names** — good for cross-checking
`scan_chains.rpt`.

**6. `dft_area.rpt` — the "after" number**

```bash
grep -i "total cell area" p2_scan/runs/c1/dft_area.rpt
cat p2_scan/runs/c1/kpi.txt
```

Overhead = `(dft_area / baseline_area - 1) × 100`. For a 129-flop design expect
roughly 10–25 %; the exact number depends entirely on the kit. Do not be
alarmed by a large number — a small UART is mostly flops, so scan costs a lot in
relative terms. Say so in the README; that is the honest framing.

### 4.2 Also check the ATPG hand-off files

`write_dft_atpg` writes into `p2_scan/test_scripts/` on Genus 21.14 (older
releases drop `*.pinassign` / `*.atpg` / `top_atpg*` straight into
`p2_scan/`); the Makefile moves all of that into `runs/c1/`:

```bash
ls -l p2_scan/runs/c1/
```

Look for `test_scripts/`, or a `*.pinassign` / `*.atpg` / `top_atpg*`. If one
exists, **it beats the template in step 5** — use it.

```bash
cat p2_scan/runs/c1/*.pinassign p2_scan/runs/c1/test_scripts/*.pinassign 2>/dev/null
```

On this install the generated file is `test_scripts/top.FULLSCAN.pinassign` and
it is five lines long: `rst_n +SC`, `SE +SE`, `clk -ES`, `dft_sdi_1 SI0`,
`dft_sdo_1 SO0`. It also ships `runmodus.atpg.tcl`, `top.test_netlist.v` and
two simulation wrappers — that script is the authoritative command syntax for
this Modus release, which is why `p2_atpg/run_atpg.tcl` follows it.

---

## Step 5 — Fix `p2_atpg/top.pinassign` (before touching Modus)

### 5.1 What a pin assignment file even is

Modus does not know your chip's pinout. `top.pinassign` is a plain text list
that tells it, for each top-level port, what role that port plays during the
test:

| Tag | Meaning | In this design |
|---|---|---|
| `+TC` / `-ES` | test clock / excluded from shift edges | `clk` |
| `+SE` | scan enable (shift vs capture) | `SE` |
| `SI<n>` | scan data in, channel *n* (0-based) | `dft_sdi_1`, ... |
| `SO<n>` | scan data out, channel *n* (prefix `-` = output on some versions) | `dft_sdo_1`, ... |
| `+TI` / `+SC` | held constant / held inactive for the whole test | `rst_n` |

Every pin you don't list is treated as an ordinary primary input that ATPG is
free to drive. That is correct and desirable for `wr_data`, `wr_en`, `rd_en`,
`baud_div`, `rx`.

### 5.2 Get the names right

```bash
cd p2_atpg
less top.pinassign
```

The file in this repo says (copied from what Genus 21.14 generated):

```
assign pin=rst_n      test_function= +SC;
assign pin=SE         test_function= +SE;
assign pin=clk        test_function= -ES;
assign pin=dft_sdi_1  test_function= SI0;
assign pin=dft_sdo_1  test_function= SO0;
```

Note the two numbering schemes: the *port* suffix is 1-based (`dft_sdi_1`),
the *channel* index in `SI0`/`SO0` is 0-based.

Now compare with reality:

```bash
grep -iE "si|so|se" ../p2_scan/runs/c1/scan_chains.rpt
head -40 ../p2_scan/runs/c1/top_scan.v
```

Three outcomes:

1. **Names match** → you are lucky, nothing to do.
2. **Names differ** (e.g. `scan_in_0`, `si`, `scan_en`) → edit the file and
   replace them. Every name must exist as a port in `top_scan.v`.
3. **`write_dft_atpg` generated a pinassign** in `runs/c1/` (on 21.14:
   `runs/c1/test_scripts/top.FULLSCAN.pinassign`) → use that file; it is
   guaranteed to match your Genus version's syntax:

   ```bash
   cp top.pinassign top.pinassign.template     # keep the template for reference
   cp ../p2_scan/runs/c1/test_scripts/*.pinassign top.pinassign
   less top.pinassign
   ```

   On this design Genus already handled `rst_n` correctly (`+SC` keeps the
   active-low reset inactive). If your generated file leaves a reset
   unassigned, add `assign pin=rst_n test_function=+TI;` — Genus cannot know it
   is a reset.

### 5.3 The `rst_n` trap

`rst_n` is **active-low asynchronous**. During scan test it must stay HIGH
(inactive) the whole time, or every chain shifts garbage. Genus 21.14 writes
`+SC` (scan control, held inactive) for it, which is correct; if you build the
file by hand, `+TI` (tie to 1) is the equivalent. Two ways this goes wrong:

- some Modus versions want an explicit value:
  `assign pin=rst_n test_function=+TI value=1;`
- or the tool treats `+TI` as "tie to 1" already and the line is fine as-is.

If step 6 fails at `verify_test_structures` with chain-shift errors, this line
is suspect #1.

### 5.4 If you are going to run more than one chain

`connect_scan_chains` creates **one SI/SO pair per chain**. With `CHAINS=4` the
netlist has `dft_sdi_1..4` / `dft_sdo_1..4` (1-based port suffix) mapped to
channels `SI0..SI3` / `SO0..SO3` (0-based channel index), and the pinassign
must list all four pairs or Modus will silently test only chain 1 and report
great coverage on a quarter of your flops.

You do not have to write these by hand: `run_atpg.tcl` regenerates
`p2_atpg/runs/c<N>/top.pinassign` from `DFT_CHAINS` on every run. Verify it:

```bash
cat p2_atpg/runs/c4/top.pinassign
grep -c "SI[0-9]" p2_atpg/runs/c4/top.pinassign   # must equal your chain count
```

Keep one pinassign per chain count if the names change:

```bash
cp top.pinassign top.pinassign.c1               # after a successful c1 run
```

and restore it before re-running `make atpg CHAINS=1` later.

---

## Step 6 — ATPG

```bash
cd ~/dft_projects/dft-scan-atpg
make atpg CHAINS=1
```

That runs `cd p2_atpg && DFT_CHAINS=1 modus -files run_atpg.tcl`, writing to
`p2_atpg/runs/c1/`.

If `modus` rejects `-files`, try the alternatives — these differ per release and
are the only reason `MODUS_FLAGS` is a Make variable:

```bash
make atpg CHAINS=1 MODUS_FLAGS='-legacy_ui -files run_atpg.tcl'
modus -help 2>&1 | head -40        # see what your release actually takes
```

or run `modus` interactively and paste the commands from `run_atpg.tcl` one at
a time. The script is plain Modus commands; nothing depends on the wrapper.

### 6.1 The failure ladder — fix in this exact order

Modus runs five things in sequence. **Each one depends on the previous.** Fix
them in order; do not skip to the coverage number.

**`build_model` — "cannot find cell / module"**

- `-cell ../lib/cells.v` points at a file that does not contain the scan flop
  the netlist uses. Check the error names the cell, then:
  `grep -c "SDFF" lib/cells.v` (or whatever your cell is called).
- If `lib/cells.v` is a **directory** of per-cell files, you cannot pass a
  directory. Concatenate:

  ```bash
  cat /path/to/models/*.v > lib/cells.v
  ```

  (Do this only if the models have no duplicate module definitions; if they do,
  include just the cells Genus mapped — `grep -oE "^ *[A-Za-z0-9_]+ +u_" p2_scan/runs/c1/top_scan.v | awk '{print $1}' | sort -u`.)

**`build_testmode` — "pin not found" / "unknown pin"**

- 100 % of the time this is a name in `top.pinassign` that does not exist in
  `top_scan.v` (typo, or the wrong chain number). Diff the two:

  ```bash
  grep -oE "^module top.*" p2_scan/runs/c1/top_scan.v
  grep "^assign" p2_atpg/top.pinassign
  ```

  Every name after `pin=` must appear in the port list.

**`verify_test_structures` — chain shifts do not work**

- `SE` not constant-high during shift, or `rst_n` active during shift, or the
  chain length Modus infers does not match the real one (pinassign lists one
  chain when there are four).
- This is a pinassign problem, *not* a netlist problem. Do not re-run Genus.

**`create_logic_tests` — this is where coverage appears**

- If it reaches here, the infrastructure is right and only the fault list
  quality varies. Now the coverage number means something.

### 6.2 Where the run log is

Modus writes its transcript **into the directory it was started from**, not into
`-files`' directory — i.e. `p2_atpg/modus.log`, rotating to `modus.log1` on the
next run. `make atpg` also tees one log per chain count, which is what you want
during the sweep (otherwise c4 overwrites c1's transcript):

```bash
ls -lt p2_atpg/modus.log*          # newest run first after rotation
ls -lt p2_atpg/runs/c1/            # atpg_kpi.txt + testresults/ live here
tail -60 p2_atpg/runs/c1/atpg.log  # after a `make atpg`
```

The `p2_atpg/flex*.log` files are tool-startup scratch, one per invocation,
and contain nothing. The per-command logs that actually hold the reports are
under `p2_atpg/runs/c1/testresults/logs/`.

### 6.3 What a good run looks like (measured on Genus 21.14 / Modus 22.10)

```
create_logic_tests:
  INFO (TDA-220):    Sim.    Eff.  Detected    Tmode    Global     Untested
  INFO (TDA-220):     91      88         22   99.99%   99.99%            0  (00:01.47)
write_vectors:
  TVE-005: Created 262 total cycles ... 258 are scan cycles
  TVE-008: Created 129 total measures, of which 129 are SO (Scan Out) measures
commit_tests:
  TBD-809: test sequence = 91, test sections = 2, tester loops = 2
  TBD-831: commit_tests completed successfully
```

129 scan-out measures = every flop is in the chain.

**Two numbers disagree, and the fault counts win.** The progress table prints
99.99 %, but the accounting behind `tbdata/modus_metrics` and the
`commit_tests` statistics table both say

```
Total Static  100.00 100.00   4556  4556  0  0  0      4556  4556  0  0  0
              ^ATcov ^Global   ^total ^tested ...     ... and 0 untested
```

4556 tested of 4556 complete stuck-at faults, 0 possible, 0 redundant, 0
untested, 0 ignored. `run_atpg.tcl` writes 100.00 into `atpg_kpi.txt` and prints
a `NOTE:` when the progress table disagrees. If you are asked the coverage in a
viva, answer with the counts: "all 4556 complete stuck-at faults tested, none
untested or ignored" — that is defensible; a lone 99.99 % against a ledger that
says 4556/4556 is not.

The `262 cycles` line is the Verilog sample dump: 2 tester loops x (129 + 1)
cycles. It is **not** the pattern count. The pattern count is the test sequence
figure from `TBD-809` (91), which is what `atpg_kpi.txt` records, so
`results_table.md` computes 91 x 130 = 11830 test cycles.

---

## Step 7 — Record the numbers

```bash
python3 scripts/collect_results.py
```

`run_atpg.tcl` fills in `p2_atpg/runs/c1/atpg_kpi.txt` itself. Everything it
writes is derived from files Modus and Genus already left on disk:

| KPI | Read from |
|---|---|
| `LONGEST_CHAIN` | `length:` fields of `p2_scan/runs/c<N>/scan_chains.rpt` |
| `TEST_COVERAGE` | `atpg.stats:static.atcov` in `tbdata/modus_metrics` (falls back to the `TDA-220` table) |
| `PATTERNS`, `NUM_TESTS` | `atpg.testmode:FULLSCAN.num_tests` |
| `TOTAL_FAULTS` | `atpg.stats:static.total_faults` |
| `DETECTED_FAULTS` | `atpg.stats:static.tested_faults` |
| `UNTESTABLE_FAULTS` | `atpg.stats:static.possible_faults` |
| `UNDETECTED_FAULTS` | `atpg.stats:static.untested_faults` |
| `NUM_EFFECTIVE_TESTS`, `ATPG_RUNTIME` | last `TDA-220` row of `log_create_logic_tests` |

Nothing needs filling in by hand. The file is still plain `KEY value` text, so
if a future release renames something, edit it by hand — hand edits survive
until the next `make atpg`.

```bash
less p2_atpg/runs/c1/atpg_kpi.txt
```

If a value came out `NA` on your release, the raw sources are:

```bash
cat p2_atpg/runs/c1/tbdata/modus_metrics | grep static
grep "TDA-220" p2_atpg/runs/c1/testresults/logs/log_create_logic_tests_FULLSCAN_top_atpg | tail -3
grep "TBD-809" -A 7 p2_atpg/runs/c1/testresults/logs/log_commit_tests_FULLSCAN_top_atpg
```

**The coverage denominator matters.** Here it is
`tested / (total − redundant − untestable)`, and on this design the ledger closes
at 4556 / 4556 with nothing excluded (`ignored_faults 0`, `untested 0`). A
scannable design of this size with no black boxes can genuinely reach 100 % —
what makes 100 % suspicious is *excluded faults*, so check `ignored_faults` and
`possible_faults` before you doubt the number. If you quote a different
definition, say which one in the README; that is exactly what an interviewer
probes.

Then:

```bash
make results
```

which rewrites `results_table.md` and `results_table.csv` with real numbers.

---

## Step 8 — The chain-count sweep (this is a deliverable)

Nothing to save: `run_atpg.tcl` regenerates `p2_atpg/runs/c<N>/top.pinassign`
for each chain count, and each count writes into its own `runs/c<N>/`, so the
counts cannot overwrite each other.

Then:

```bash
bash scripts/sweep_chains.sh 1 2 4 8
```

What it does: for each count, `make dft CHAINS=n` then `make atpg CHAINS=n`,
into separate `runs/c1`, `runs/c2`, `runs/c4`, `runs/c8` directories — nothing
overwrites anything. If ATPG fails for one count, the script warns and keeps
going, so a bad 8-chain run does not cost you the other three data points.

**Expect to babysit this.** After each `dft` step, do the step-5 check for the new
chain count:

```bash
grep -c "test_function=+SI" p2_atpg/top.pinassign    # must equal the chain count
```

If the new netlist names chains differently, copy the generated pinassign for
that count into place, or run the sweep one count at a time and fix in between:

```bash
bash scripts/sweep_chains.sh 1 2
# fix pinassign for 2 chains
bash scripts/sweep_chains.sh 4 8
```

After each successful `atpg`, fill that count's `atpg_kpi.txt`, then run
`make results` again. The table fills in row by row.

Expected shape of the results (this is the point of the experiment, and the
reason it is a good interview story):

| Chains | Longest chain | Test cycles | ATPG runtime |
|---|---|---|---|
| 1 | ~129 | ~130 × patterns | slowest |
| 2 | ~65 | half | faster |
| 4 | ~33 | quarter | faster |
| 8 | ~17 | eighth | start-up cost dominates |

Area overhead barely moves (±1 %), because you are trading routing and pins for
time, not adding logic.

---

## Step 9 — Gate-level replay of the patterns

This is the step that turns "ATPG says 97 %" into "the patterns actually
produce those results on the real netlist". It is also the step that catches a
wrong pin assignment once and for all.

### 9.1 Look at what ATPG gave you

```bash
head -60 p2_atpg/runs/c1/top_vec.v        # find it: find . -name "top_vec.v"
```

Note the port list and the clocking. That header decides the exact stimulus,
which is why `tb_gls.v` cannot be written before this run — it does not exist
yet, and that is expected, not an oversight.

### 9.2 Write `p2_atpg/tb_gls.v`

Start from `rtl/tb_top.v`: it already knows how to drive `clk`, `rst_n`,
`baud_div` and both FIFO interfaces. Change:

1. instantiate `top` from `p2_scan/runs/c1/top_scan.v` (not `rtl/top.v`),
2. instantiate the vector module from `top_vec.v`,
3. drive the netlist inputs from the vector module's outputs each cycle,
4. compare the netlist outputs against the vector module's expected outputs,
   counting mismatches,
5. print `PASS` only if mismatches are zero.

### 9.3 Run it

```bash
iverilog -g2012 -o p2_atpg/runs/c1/gls.vvp \
    p2_scan/runs/c1/top_scan.v lib/cells.v \
    p2_atpg/runs/c1/top_vec.v p2_atpg/tb_gls.v
cd p2_atpg/runs/c1 && vvp gls.vvp
```

or with Xcelium (usually available wherever Genus is):

```bash
xrun -64bit -access +rwc -elaborate \
     p2_scan/runs/c1/top_scan.v lib/cells.v \
     p2_atpg/runs/c1/top_vec.v p2_atpg/tb_gls.v
```

### 9.4 Two X-noise sources that are not bugs

1. The FIFO storage flops have no reset, so they are X until written. If the
   first patterns disagree only on `rd_data`, that is X-propagation from
   unwritten memory, not a broken pattern.
2. `rx` is an ordinary input in vector mode. If it is X, the RX FSM goes X and
   the chain shifts X. Check that `top_vec.v` actually drives `rx` (and that the
   pinassign does not tie it somewhere odd).

Anything else — especially mismatches on `tx`, `tx_busy`, `fifo_status` after a
few cycles — is real. Most likely cause: `SE` polarity or `rst_n` in the
pinassign.

---

## Step 10 — Commit and document

```bash
mkdir -p report
cp p2_scan/runs/baseline/baseline_area.rpt p2_scan/runs/baseline/baseline_timing.rpt report/
cp p2_scan/runs/c1/dft_rules_pre.rpt p2_scan/runs/c1/dft_rules_post.rpt \
   p2_scan/runs/c1/scan_setup.rpt p2_scan/runs/c1/scan_chains.rpt \
   p2_scan/runs/c1/dft_area.rpt report/
cp p2_atpg/top.pinassign report/
cp results_table.md results_table.csv report/
git add report results_table* README.md
git commit -m "Add Genus/Modus results from server run"
```

Then in `README.md`:

1. paste `results_table.md` into the Results section (replace the `<N>/<K>/...`
   placeholders in the resume bullets too),
2. state the exact tool versions (`genus -version`, `modus -version`) and the
   library corner,
3. state your coverage definition,
4. write down anything the tools surprised you with. That paragraph is worth
   more in an interview than the numbers.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `genus: command not found` | environment not loaded | step 1; `module load genus` |
| Hang at startup, no output | waiting for a licence | check `LM_LICENSE_FILE`; try `genus -version` first |
| `cannot open library file cells.lib` | symlink wrong or relative | re-do step 2.2 with an absolute path |
| `Cannot find the cell ... in library` | Liberty and netlist disagree, or wrong corner | check the cell exists: `grep -c "cell (CELLNAME" lib/cells.lib` |
| `connect_scan_chains` does nothing / 0 chains | no scan flops in the library, or `syn_map` before scan style | `grep -ci sdf lib/cells.lib`; version table below |
| `define_shift_enable` error | command renamed in your release | version table below (row 2) |
| Genus ends with `exit` code 1 and no error | report redirect syntax | version table (row 5) |
| Scan flops 0 but library has them | scan style set after `syn_map` | use `set_db dft_scan_style` **before** `syn_generic` (it is, in `dft.tcl`) |
| Modus `build_model`: module not found | `cells.v` missing that cell | step 6.1 |
| Modus `build_testmode`: pin not found | wrong name in `top.pinassign` | step 5.2 |
| Modus `verify_test_structures`: shift error | `SE` polarity / `rst_n` not tied / one chain listed of many | step 5.3, 5.4 |
| Coverage 100 % on 1/4 of the flops | pinassign lists one SI/SO pair for 4 chains | step 5.4 |
| Modus: `FlexNet Licensing checkout error: No such feature exists` for `Modus_Test`, then `free(): invalid size` + `Aborted (core dumped)` | licence server not offering the Modus features to this host — nothing to do with the scripts | see "Licence failures" below |
| `SyntaxError: future feature annotations is not defined` | server's `python3` is older than the local one | `python3 -V`; the shipped `collect_results.py` is 3.6-safe, so a stale copy is on the server |
| `results_table.md` full of `?` | `atpg_kpi.txt` not filled, or `kpi.txt` has `NA` | steps 3.2 and 7 |
| Table shows overhead `?` | baseline area missing | `make baseline`, then `make results` |

### Licence failures (Modus aborts before your script runs)

A failed checkout looks like this, and the `tclsh $fwPrompt` crash right after
it is a symptom, not a second bug:

```
Checkout succeeded: Modus_common_ui/...            <- server reachable
FlexNet Licensing checkout error: No such feature exists.
Feature:       Modus_Test          FlexNet Licensing error:-5,147
free(): invalid size
.modus.native: line 2103: 1252442 Aborted (core dumped) tclsh $fwPrompt
```

`-5,147` means *the server does not serve that feature*, as opposed to all seats
being busy (`-4`) or the server being unreachable (`-15`). Things to check, in
order:

```bash
hostname -f                              # is this the node you ran on before?
printenv | grep -iE "lic|cds"            # which servers are configured
lmstat -a -c 5280@14.139.1.126 | head -25 # daemon up? feature list? expiry dates?
lmstat -a -c 5280@14.139.1.126 | grep -i modus
make baseline                            # does Genus still get a licence?
```

Read the interpretation before you change anything:

- **Genus works, Modus does not** -> only the Modus features changed. Contact
  the lab admin; there is nothing to fix in this repo, and re-running `make atpg`
  in a loop will not help.
- **`lmstat` shows no `Modus_Test` at all** -> the licence file on the server was
  edited or the feature expired; only the admin can fix that.
- **`lmstat` shows `Modus_Test` with `Users of ...:` entries** -> seats are taken;
  wait or ask the holder to release.
- **Different login node than your earlier successful run** -> some academic
  licences are tied to specific hosts; go back to the node where it worked.

The one thing worth keeping: the very same `run_atpg.tcl` completed a full ATPG
run on this project before, so a licence failure on a later day says nothing
about the script. Do not "fix" the Tcl to chase it.

### What actually needs changing if your release differs

These are the only version-sensitive lines in the whole project. Each is a
one-line edit and changes no methodology.

| File | Line | If it errors, try |
|---|---|---|
| `p2_scan/dft.tcl` | `set_db dft_scan_style muxed_scan` | `set_db / .dft_scan_style muxed_scan` |
| `p2_scan/dft.tcl` | `define_shift_enable -name SE -active high -create_port SE` | `create_test_protocol -shift_enable SE`, or set `dft_shift_enable_port` per your version's DRC |
| `p2_scan/dft.tcl` | `set_db design:/top .dft_min_number_of_scan_chains` | already tries `design:/top` then `design:top`; if both fail, use `set_db [get_db designs top] .dft_min_number_of_scan_chains` |
| `p2_scan/dft.tcl` | `write_dft_atpg -library ../lib/cells.v` | `write_dft_atpg` with no `-library`, then pass `cells.v` to Modus yourself |
| `baseline.tcl`, `dft.tcl` | `report_area > $::OUT/...` | `report_area -output $::OUT/...` |
| both `p2_scan/*.tcl` | `genus -f script.tcl` | `genus -files script.tcl` |
| `p2_atpg/run_atpg.tcl` | `modus -files run_atpg.tcl` | `modus -legacy_ui -files ...`, or paste commands interactively |
| `p2_scan/top.sdc` | `[remove_from_collection ...]` | if unsupported, drop it: `set_input_delay 2 -clock clk [all_inputs]` (includes `clk` — harmless here) |

### Things you will forget, so write them down now

1. Which cell library and corner you used.
2. The exact SI/SO/SE names Genus created.
3. Baseline area and flop count.
4. Which start-up/licence incantation worked on this server.
5. Every workaround you applied — those are the interesting part of the story.
