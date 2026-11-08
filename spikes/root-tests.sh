#!/bin/bash
# Phase-0 tests that need admin rights. Run:  sudo ./root-tests.sh
#
#   1. memcap as root — can root hard-cap an already-running process?
#   2. Install talond as a LaunchDaemon, talk to it over XPC as YOU,
#      have it hard-cap a running process, check its safety rule.
#   3. Uninstall the helper again (this is only a test).
#
# Writes everything to results-root.txt next to this script.
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with: sudo $0"; exit 1; }
: "${SUDO_UID:?Run via sudo from your own account}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/results-root.txt"
LABEL=dev.talon.helper
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

exec > >(tee "$OUT") 2>&1
echo "== 1. Hard cap as root ($(date))"
"$DIR/2-memcap/memcap" 300

echo
echo "== 2. Admin helper over XPC"
mkdir -p /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$DIR/5-helper/talond" "$BIN"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>--allowed-uid</string><string>$SUDO_UID</string></array>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>StandardErrorPath</key><string>/var/log/$LABEL.log</string>
</dict></plist>
EOF
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootout system/$LABEL 2>/dev/null || true
if launchctl bootstrap system "$PLIST"; then
  echo "  ✅ helper installed and registered with launchd"
  sudo -u "#$SUDO_UID" "$DIR/5-helper/helper-client" "$DIR/2-memcap/memcap"
else
  echo "  ❌ launchctl bootstrap failed"
fi
echo "  helper log:"; tail -5 /var/log/$LABEL.log 2>/dev/null | sed 's/^/    /'

echo
echo "== 3. Uninstall helper"
launchctl bootout system/$LABEL 2>/dev/null || true
rm -f "$PLIST" "$BIN" /var/log/$LABEL.log
echo "  removed ✓"
chown "$SUDO_UID" "$OUT"
