#!/bin/bash
# Spike 6.1 — scan speed. A full, read-only scan of the home folder: wall time, CPU, items/s,
# and whether a 1 Hz timer (standing in for talond's sampler) notices.
# Read-only: getattrlistbulk only. Duplicate hashing is off so no file contents are read.
# Needs `ScalpelCommand` registered in Sources/talon/Talon.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release --product talon >/dev/null
TALON=$(swift build -c release --show-bin-path)/talon
OUT=$(mktemp -d)
swiftc -O spikes/6-scalpel/jitter.swift -o "$OUT/jitter" 2>/dev/null

echo "== baseline: 1 Hz timer, idle (10 s)"
"$OUT/jitter" 10

for run in first second; do
    echo "== $run scan of ~ (1 Hz timer running alongside)"
    "$OUT/jitter" 30 > "$OUT/jitter-$run.txt" &
    J=$!
    /usr/bin/time -l "$TALON" scalpel scan ~ --no-duplicates --json > "$OUT/scan-$run.json" 2> "$OUT/time-$run.txt"
    wait $J
    jq -r '.stats | "files \(.files) · folders \(.directories) · symlinks \(.symlinks) · wall \(.seconds|.*100|round/100) s · scan CPU \(.cpuSeconds|.*100|round/100) s · items/s \(((.files+.directories)/.seconds)|round) · clone groups \(.cloneGroups) · hard-link groups \(.hardLinkGroups) · unreadable \(.unreadable|length) · other volumes \(.otherVolumes|length)"' "$OUT/scan-$run.json"
    jq -r '"totals: logical \(.totals.logical/1073741824*10|round/10) GB · on disk \(.totals.onDisk/1073741824*10|round/10) GB · reclaimable \(.totals.reclaimable/1073741824*10|round/10) GB · findings \(.findings|length)"' "$OUT/scan-$run.json"
    grep -E "real|maximum resident|instructions retired|cycles elapsed|involuntary context" "$OUT/time-$run.txt" | sed 's/^/  /'
    echo -n "  timer during scan: "; cat "$OUT/jitter-$run.txt"
done
echo "== unreadable (first 10)"
jq -r '.stats.unreadable[:10][] | "  \(.path) — \(.reason)"' "$OUT/scan-second.json"
rm -rf "$OUT"
