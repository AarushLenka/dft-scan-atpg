# lib/ — cell library goes here

The Cadence flow needs two files, and both come from the PDK / standard-cell
kit on your SSH server — they cannot be committed here (licence + size):

| File | Used by | Contents |
|------|---------|----------|
| `cells.lib` | Genus (`set_db library cells.lib`) | Liberty timing/area model |
| `cells.v`   | Modus (`-cell ../lib/cells.v`), gate-level sim | Verilog behavioural models |

The scripts in `p2_scan/` and `p2_atpg/` expect these exact names, so either
copy/link the PDK files to `lib/cells.lib` and `lib/cells.v`:

```bash
ln -sf /path/to/pdk/lib/your_cell.lib      lib/cells.lib
ln -sf /path/to/pdk/lib/your_cell.v        lib/cells.v
```

or edit `set_db library` in `p2_scan/baseline.tcl` / `p2_scan/dft.tcl`.

## Requirements the library must satisfy

1. **Scan flip-flops must exist.** Full-scan insertion needs `SDFF`-style cells
   (a flop with an SE pin or, for clocked-scan, a separate scan clock). If the
   library has only plain `DFF`s, Genus cannot map the scan style and
   `connect_scan_chains` will fail or fall back to nothing.
2. **`cells.v` must model the same scan flops** with the same pin names, or
   Modus `build_model` and gate-level simulation will not match the netlist.
3. Both files must describe the **same** cells. Mixing a Liberty file from one
   kit with a Verilog model from another is the most common cause of
   "cell not found" / mismatched-port errors.

If the kit ships `.db` (Synopsys) or `.lef` only, use the Liberty (`.lib`) —
Genus reads Liberty directly; `.db` needs `lc_shell` conversion first.
