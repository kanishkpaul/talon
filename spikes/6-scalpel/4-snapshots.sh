#!/bin/bash
# Spike 6.4 — snapshot-held and purgeable space, measured without admin rights.
# LIST ONLY: never deletes or thins a snapshot, never uses sudo.
set -uo pipefail
DATA=$(df / /System/Volumes/Data | awk 'NR==3 {print $1}')

echo "== tmutil listlocalsnapshots /"
tmutil listlocalsnapshots / 2>&1
echo "== tmutil listlocalsnapshotdates /"
tmutil listlocalsnapshotdates / 2>&1
echo "== diskutil apfs listSnapshots $DATA (Data volume)"
diskutil apfs listSnapshots "$DATA" 2>&1 | head -30
echo "== diskutil apfs listSnapshots / (sealed system volume)"
diskutil apfs listSnapshots / 2>&1 | head -12
echo "== diskutil info $DATA: space"
diskutil info "$DATA" 2>&1 | grep -iE "volume (used|free)|container (total|free)|purgeable|available space|capacity consumed"
echo "== diskutil apfs list: the container"
diskutil apfs list 2>&1 | grep -iE "capacity|snapshot|^\s+\+-- Container|Data\)" | head -12
echo "== statfs free vs Finder's 'available' (includes purgeable)"
swift -e '
import Foundation
var s = statfs(); statfs("/System/Volumes/Data", &s)
let free = Double(s.f_bavail) * Double(s.f_bsize)
let v = try! URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey, .volumeAvailableCapacityKey])
func gb(_ x: Double) -> String { String(format: "%.1f GB", x / 1e9) }
print("statfs free             ", gb(free))
print("available (important)   ", gb(Double(v.volumeAvailableCapacityForImportantUsage ?? 0)), " ← Finder; counts purgeable")
print("available (opportunistic)", gb(Double(v.volumeAvailableCapacityForOpportunisticUsage ?? 0)))
print("purgeable estimate      ", gb(Double(v.volumeAvailableCapacityForImportantUsage ?? 0) - free))
' 2>&1
