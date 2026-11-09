#!/bin/bash
# Spike 6.5 — app leftovers. Runs the matcher against the real ~/Library (read-only, no size floor)
# and prints every candidate with what Spotlight and /Applications say about it, for spot-checking.
# Nothing is moved or removed. Needs `ScalpelCommand` registered in Sources/talon/Talon.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release --product talon >/dev/null
TALON="$(swift build -c release --show-bin-path)/talon"
OUT=$(mktemp -d)
"$TALON" scalpel scan ~ --no-duplicates --min-size 0 --json > "$OUT/scan.json"
echo "candidates: $(jq '[.findings[] | select(.category=="app-leftovers")] | length' "$OUT/scan.json")"
jq -r '.findings[] | select(.category=="app-leftovers") | [.ownerBundleID, (.sizes.reclaimable|tostring), (.lastUsed // "-"), (.paths|map(sub(env.HOME+"/";"~/"))|join(" | "))] | @tsv' "$OUT/scan.json" |
while IFS=$'\t' read -r id bytes last paths; do
    spot=$(mdfind "kMDItemCFBundleIdentifier == '$id'c" 2>/dev/null | head -1)
    printf '%-58s %9s B  last %s  spotlight: %s\n    %s\n' "$id" "$bytes" "${last%%T*}" "${spot:-none}" "$paths"
done
rm -rf "$OUT"
