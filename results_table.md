| Chains (requested) | Chains built | Scan flops | Longest chain | Patterns | Approx. test cycles | Coverage | Area overhead | ATPG runtime (s) |
|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 129 | 129 | 91 | 11830 | 100.00% | 17.2% | 1.5 |
| 2 | 2 | 129 | 65 | 92 | 6072 | 100.00% | 17.2% | 2.3 |
| 4 | 4 | 129 | 33 | 93 | 3162 | 100.00% | 17.2% | 4.7 |
| 8 | 8 | 129 | 17 | 94 | 1692 | 100.00% | 17.2% | 1.3 |

> Baseline (no-DFT) cell area: 4312.82
> Approx. test cycles = patterns x (longest chain + 1); coverage and pattern counts come from p2_atpg/runs/c<N>/atpg_kpi.txt.
