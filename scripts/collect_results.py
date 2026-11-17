#!/usr/bin/env python3
"""Collect Genus/Modus run KPIs into the project results table.

Inputs (whatever exists; missing values show up as "?"):

  p2_scan/runs/baseline/kpi.txt    AREA_CELL, NUM_FLIPFLOPS   (written by baseline.tcl)
  p2_scan/runs/c<N>/kpi.txt        AREA_CELL, NUM_SCAN_CHAINS  (written by dft.tcl)
  p2_atpg/runs/c<N>/atpg_kpi.txt   coverage / test counts, written by
                                   run_atpg.tcl itself (a template with "?"
                                   is created if the ATPG run never happened)

Outputs:

  results_table.md   markdown table for the README
  results_table.csv  same data for spreadsheets

Usage:
  python3 scripts/collect_results.py
  python3 scripts/collect_results.py --selftest
"""

# Keep this script importable by the Python 3.6 that ships with older
# enterprise Linux images: no `from __future__ import annotations`, no
# PEP 585/604 annotations, no walrus.
import argparse
import csv
import re
import sys
from pathlib import Path

SCAN_DIR = Path("p2_scan/runs")
ATPG_DIR = Path("p2_atpg/runs")
CSV_OUT = Path("results_table.csv")
MD_OUT = Path("results_table.md")

ATPG_TEMPLATE = """\
# Copy these numbers out of the Modus logs for this chain count, one KEY value
# per line. Lines starting with # are ignored.
#
#   LONGEST_CHAIN        longest scan chain length (scan_chains.rpt / Modus DRC)
#   PATTERNS             committed stuck-at patterns
#   TEST_COVERAGE        test coverage %, digits only
#   TOTAL_FAULTS         total stuck-at faults
#   DETECTED_FAULTS      detected faults
#   UNTESTABLE_FAULTS    ATPG-untestable faults
#   ATPG_RUNTIME         runtime in seconds
LONGEST_CHAIN       ?
PATTERNS            ?
TEST_COVERAGE       ?
TOTAL_FAULTS        ?
DETECTED_FAULTS     ?
UNTESTABLE_FAULTS   ?
ATPG_RUNTIME        ?
"""

COLUMNS = [
    ("chains", "Chains (requested)", "0"),
    ("chains_built", "Chains built", "0"),
    ("scan_flops", "Scan flops", "0"),
    ("longest_chain", "Longest chain", "0"),
    ("patterns", "Patterns", "0"),
    ("cycles", "Approx. test cycles", "0"),
    ("coverage", "Coverage", "2"),
    ("overhead", "Area overhead", "1"),
    ("runtime", "ATPG runtime (s)", "1"),
]


def read_kpi(path: Path) -> dict:
    """Parse 'KEY value' lines. Missing file -> empty dict."""
    data = {}
    if not path.is_file():
        return data
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            data[parts[0].upper()] = parts[1].strip()
    return data


def number(data: dict, key: str):
    raw = data.get(key)
    if raw is None:
        return None
    raw = raw.replace(",", "").replace("%", "").strip()
    try:
        return float(raw)
    except ValueError:
        return None


def find_scan_runs(root: Path) -> dict:
    runs = {}
    for d in sorted((root / SCAN_DIR).glob("c[0-9]*")):
        m = re.fullmatch(r"c(\d+)", d.name)
        if m:
            runs[int(m.group(1))] = read_kpi(d / "kpi.txt")
    return runs


def find_atpg_runs(root: Path) -> dict:
    runs = {}
    for d in sorted((root / ATPG_DIR).glob("c[0-9]*")):
        m = re.fullmatch(r"c(\d+)", d.name)
        if not m:
            continue
        kpi = d / "atpg_kpi.txt"
        if not kpi.is_file():
            kpi.write_text(ATPG_TEMPLATE)
        runs[int(m.group(1))] = read_kpi(kpi)
    return runs


def build_rows(baseline_area, scan_runs: dict, atpg_runs: dict) -> list:
    """Pure function: one row per chain count, plus derived numbers."""
    rows = []
    for chains in sorted(scan_runs):
        scan = scan_runs[chains]
        atpg = atpg_runs.get(chains, {})

        area = number(scan, "AREA_CELL")
        overhead = None
        if area is not None and baseline_area:
            overhead = (area - baseline_area) / baseline_area * 100.0

        longest = number(atpg, "LONGEST_CHAIN")
        patterns = number(atpg, "PATTERNS")
        cycles = None
        if longest is not None and patterns is not None:
            cycles = patterns * (longest + 1)

        rows.append(
            {
                "chains": chains,
                "chains_built": number(scan, "NUM_SCAN_CHAINS"),
                "scan_flops": number(scan, "NUM_FLIPFLOPS"),
                "longest_chain": longest,
                "patterns": patterns,
                "cycles": cycles,
                "coverage": number(atpg, "TEST_COVERAGE"),
                "overhead": overhead,
                "runtime": number(atpg, "ATPG_RUNTIME"),
            }
        )
    return rows


def cell(value, digits: str) -> str:
    if value is None:
        return "?"
    # ATPG coverage lands in the high nineties, where one decimal rounds 99.99
    # up to a claim of 100% -- hence the per-column precision.
    return ("{:." + digits + "f}").format(value)


def render_markdown(rows: list, baseline_area) -> str:
    head = "| " + " | ".join(c[1] for c in COLUMNS) + " |"
    rule = "|" + "|".join("---" for _ in COLUMNS) + "|"
    lines = [head, rule]
    for row in rows:
        cells = []
        for key, _label, digits in COLUMNS:
            suffix = "%" if key in ("coverage", "overhead") else ""
            cells.append(cell(row[key], digits) + suffix if row[key] is not None else "?")
        lines.append("| " + " | ".join(cells) + " |")

    lines.append("")
    if baseline_area is None:
        lines.append(
            "> No baseline area found (p2_scan/runs/baseline/kpi.txt). "
            "Run `make baseline` first."
        )
    else:
        lines.append("> Baseline (no-DFT) cell area: {:.2f}".format(baseline_area))
    if not rows:
        lines.append("> No DFT runs found under p2_scan/runs/c<N>. Run `make dft CHAINS=1`.")
    lines.append(
        "> Approx. test cycles = patterns x (longest chain + 1); "
        "coverage and pattern counts come from p2_atpg/runs/c<N>/atpg_kpi.txt."
    )
    return "\n".join(lines) + "\n"


def write_csv(rows: list, path: Path) -> None:
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=[c[0] for c in COLUMNS])
        writer.writeheader()
        for row in rows:
            writer.writerow({k: ("" if row[k] is None else row[k]) for k in row})


def selftest() -> int:
    scan_runs = {
        1: {"AREA_CELL": "1200.0", "NUM_FLIPFLOPS": "129", "NUM_SCAN_CHAINS": "1"},
        4: {"AREA_CELL": "1,320.5", "NUM_FLIPFLOPS": "129", "NUM_SCAN_CHAINS": "4"},
    }
    atpg_runs = {
        1: {"LONGEST_CHAIN": "129", "PATTERNS": "42", "TEST_COVERAGE": "97.5%"},
        4: {"LONGEST_CHAIN": "33", "PATTERNS": "45", "TEST_COVERAGE": "97.5"},
    }
    rows = build_rows(1000.0, scan_runs, atpg_runs)

    assert [r["chains"] for r in rows] == [1, 4], rows
    assert abs(rows[0]["overhead"] - 20.0) < 1e-9, rows[0]["overhead"]
    assert abs(rows[1]["overhead"] - 32.05) < 1e-9, rows[1]["overhead"]
    assert rows[0]["cycles"] == 42 * 130, rows[0]["cycles"]
    assert rows[1]["cycles"] == 45 * 34, rows[1]["cycles"]
    assert rows[0]["coverage"] == 97.5, rows[0]["coverage"]
    assert rows[1]["scan_flops"] == 129, rows[1]["scan_flops"]

    md = render_markdown(rows, 1000.0)
    assert "| 1 | 1 | 129 |" in md, md

    # This script must keep running on the server's python3, which is 3.6 or
    # older on many Cadence images -- newer interpreters happily parse 3.7+
    # syntax, so check for the construct that is easy to reintroduce.
    own = Path(__file__).read_text()
    assert not re.search(r":\s*(dict|list|tuple|set)\[", own), (
        "PEP 585 annotation, needs python 3.9"
    )

    empty = build_rows(None, {}, {})
    assert empty == []
    assert "No baseline area" in render_markdown(empty, None)

    print("selftest: OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=".", help="project root (default: .)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    root = Path(args.root).resolve()
    baseline = read_kpi(root / SCAN_DIR / "baseline" / "kpi.txt")
    baseline_area = number(baseline, "AREA_CELL")

    rows = build_rows(baseline_area, find_scan_runs(root), find_atpg_runs(root))
    md = render_markdown(rows, baseline_area)

    (root / MD_OUT).write_text(md)
    write_csv(rows, root / CSV_OUT)

    print(md)
    print("wrote {} and {}".format(MD_OUT, CSV_OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
