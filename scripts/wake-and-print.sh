#!/usr/bin/env bash
#
# Wait for the Phaser 3020 to appear on USB (it sleeps off the bus), then print.
# Usage: scripts/wake-and-print.sh [file-to-print]   (defaults to the test page)
#
set -euo pipefail
QUEUE="${QUEUE:-Xerox_Phaser_3020}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${1:-$REPO/test/test-page.pdf}"
[ -f "$DOC" ] && [ -r "$DOC" ] || { echo "Cannot read file: $DOC"; exit 1; }
# Watch the device assigned to this queue, not any similarly named printer.
queue_device="$(lpstat -v "$QUEUE")"
URI="${queue_device#*: }"
case "$URI" in
  usb://Xerox/Phaser%203020*) ;;
  *) echo "Queue '$QUEUE' is not configured for a USB Phaser 3020. Run bootstrap.sh."; exit 1 ;;
esac

echo "Waiting for the Phaser 3020 on USB — press its power/wake button if it's asleep…"
for _ in $(seq 1 60); do
  if ! devices="$(lpinfo -v 2>&1)"; then
    echo "Cannot query the printing service: $devices"; exit 1
  fi
  if printf '%s\n' "$devices" | awk -v uri="$URI" '$2 == uri {found=1} END {exit !found}'; then
    echo
    echo "✓ Printer detected. Sending: $DOC"
    lp -d "$QUEUE" -- "$DOC"
    sleep 2
    lpstat -p "$QUEUE"
    exit 0
  fi
  printf "."
  sleep 2
done
echo
echo "✗ Timed out (120s): the printer never appeared on USB."
echo "  Check it's powered on and awake, and that the USB cable is seated (try a direct port)."
exit 1
