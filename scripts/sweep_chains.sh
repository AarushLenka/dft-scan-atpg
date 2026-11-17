#!/usr/bin/env bash
# Sweep the number of scan chains through Genus + Modus and rebuild the table.
#
#   bash scripts/sweep_chains.sh          # 1 2 4 8
#   bash scripts/sweep_chains.sh 1 2      # just these
#
# Each chain count gets its own run directory, so earlier results are never
# overwritten: p2_scan/runs/c<N>/ and p2_atpg/runs/c<N>/.
set -euo pipefail
cd "$(dirname "$0")/.."

chains=("$@")
if [ ${#chains[@]} -eq 0 ]; then
    chains=(1 2 4 8)
fi

for c in "${chains[@]}"; do
    echo
    echo "=============== scan chains = $c ==============="

    make dft CHAINS="$c"

    # ATPG failures should not abort the sweep: keep the netlist and move on so
    # one bad chain count does not cost you the other data points.
    if ! make atpg CHAINS="$c"; then
        echo "WARNING: Modus failed for CHAINS=$c (netlist kept in p2_scan/runs/c$c)"
    fi
done

make results
