#!/usr/bin/env bash
# Read-only checks. No installation, queue changes, or print jobs.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST=/Library/Printers/Xerox/P3020
QUEUE="${QUEUE:-Xerox_Phaser_3020}"
failed=0
[ "$(uname)" = Darwin ] || { echo "This is for macOS only."; exit 1; }
echo "macOS $(sw_vers -productVersion), $(uname -m)"
if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "OK: Intel execution is available."
else
  echo "FAIL: Intel execution is unavailable; run bootstrap.sh to check Rosetta."
  failed=1
fi
for target in "$REPO/driver/rastertosec" "$DEST/rastertosec"; do
  if [ "$target" = "$REPO/driver/rastertosec" ]; then
    output="$(/usr/bin/arch -x86_64 "$target" </dev/null 2>&1 || true)"
  else
    output="$("$target" </dev/null 2>&1 || true)"
  fi
  case "$output" in
    *"ERROR: rastertopcl job-id user title copies options [file]"*) echo "OK: $target loads." ;;
    *) echo "FAIL: $target: $output"; failed=1 ;;
  esac
done
if [ -f "$DEST/rastertosec.bin" ] && /usr/bin/cmp -s "$REPO/scripts/filter-launcher.sh" "$DEST/rastertosec"; then
  echo "OK: explicit x86_64 CUPS launcher installed."
else
  echo "FAIL: CUPS launcher is missing or outdated; rerun bootstrap.sh."
  failed=1
fi
if devices="$(lpinfo -v 2>&1)"; then
  if printf '%s\n' "$devices" | awk 'tolower($2) ~ /^usb:\/\/xerox\/phaser%203020([?\/]|$)/ {found=1} END {exit !found}'; then
    echo "OK: Phaser 3020 detected on USB."
  else
    echo "FAIL: Phaser 3020 not on USB. Wake it and check the cable."
    failed=1
  fi
else
  echo "FAIL: cannot query the printing service: $devices"
  failed=1
fi
if ! lpstat -p "$QUEUE"; then failed=1; fi
exit "$failed"
