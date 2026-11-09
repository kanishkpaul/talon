#!/bin/bash
# Spike 6.3 — duplicate → clone. In a fresh temp dir: an original and a byte-identical copy (real
# blocks, not a clone) whose metadata differs. Run `talon scalpel dedupe --yes`, then check the copy kept
# its own xattrs, mode, flags and dates, now shares the original's blocks, and the space came back.
# Needs `ScalpelCommand` registered in Sources/talon/Talon.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release --product talon >/dev/null
TALON="$(swift build -c release --show-bin-path)/talon"
T=$(mktemp -d)
trap 'chflags -R nohidden "$T"; rm -rf "$T"' EXIT

head -c 67108864 /dev/urandom > "$T/original.bin"
xattr -w com.example.source original "$T/original.bin"
touch -t 201801010000 "$T/original.bin"                 # oldest copy is the one kept
mkdir "$T/copies"
cat "$T/original.bin" > "$T/copies/copy.bin"            # same bytes, separate blocks
xattr -w com.example.note "keep me" "$T/copies/copy.bin"
xattr -w com.apple.metadata:kMDItemWhereFroms "https://example.com/x" "$T/copies/copy.bin"
chmod 600 "$T/copies/copy.bin"
touch -t 202001020304.05 "$T/copies/copy.bin"           # also pulls the birth date back
chflags hidden "$T/copies/copy.bin"
sync

show() {
    stat -f "  mode %Sp · flags %Sf · born %SB · modified %Sm · inode %i" -t "%F %T" "$T/copies/copy.bin"
    xattr "$T/copies/copy.bin" | sed 's/^/  xattr /'
}
free() { df -k "$T" | awk 'NR==2 {print $4}'; }

echo "== before"; show
F0=$(free)
"$TALON" scalpel dedupe "$T" --min-size 1M --yes
sync; sleep 1
echo "== after"; show
F1=$(free)
echo "== free space change: $(( (F1 - F0) / 1024 )) MiB (expected +64)"
cmp -s "$T/original.bin" "$T/copies/copy.bin" && echo "== contents identical"
echo "== original's xattrs (unchanged):"; xattr "$T/original.bin" | sed 's/^/  /'
"$TALON" scalpel why "$T/copies/copy.bin" | sed -n '1,4p'
