#!/bin/bash
# Spike 6.1b — how many directory reads in flight? Total kernel CPU vs wall time for 1, 2, 4, 8 workers
# (map only, read-only). Plus the per-attribute kernel cost on ~/Library (attrcost.c, single thread).
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release --product talon >/dev/null
TALON="$(swift build -c release --show-bin-path)/talon"
for w in 1 2 4 8; do
    echo -n "workers $w: "
    "$TALON" scalpel scan ~ --map-only --workers "$w" --json \
        | jq -r '.stats | "wall \(.seconds*10|round/10) s · CPU \(.cpuSeconds*10|round/10) s · \(((.files+.directories)/.seconds)|round) items/s"'
done
OUT=$(mktemp -d)
clang -O2 -o "$OUT/attrcost" spikes/6-scalpel/attrcost.c
"$OUT/attrcost" ~/Library
rm -rf "$OUT"
