#!/usr/bin/env bash
# Syntax-check the Cadence Tcl scripts without Cadence installed.
#
# Every vendor command (set_db, syn_map, build_model, ...) is stubbed via Tcl's
# `unknown`, the script is sourced in a throwaway directory, and any Tcl syntax
# error (missing brace/bracket, bad variable ref) aborts. This does NOT check
# Genus/Modus command semantics -- only that the scripts parse and run as Tcl.
#
#   bash scripts/check_tcl.sh      # or: make tclcheck
set -uo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

run_tcl() {
    local script="$1" chains="${2:-}"
    local out
    out=$(
        cd "$tmp" || exit 1
        if [ -n "$chains" ]; then export DFT_CHAINS="$chains"; fi
        tclsh <<EOF 2>&1
proc unknown {args} { return "" }
source {$root/$script}
EOF
    )
    local status=$?
    if [ $status -ne 0 ]; then
        echo "FAIL ($status) $script${chains:+ [CHAINS=$chains]}"
        echo "$out" | sed 's/^/    /' | head -20
        fail=1
    else
        echo "ok   $script${chains:+ [CHAINS=$chains]}"
    fi
}

run_tcl p2_scan/baseline.tcl
run_tcl p2_scan/dft.tcl 1
run_tcl p2_scan/dft.tcl 4
run_tcl p2_atpg/run_atpg.tcl 1
run_tcl p2_atpg/run_atpg.tcl 8

exit $fail
