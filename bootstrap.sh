#!/usr/bin/env bash
#
# One-command setup for the Xerox Phaser 3020 on macOS (Apple Silicon or Intel).
# Installs Rosetta 2 if needed, installs the bundled vendor driver, and creates a
# CUPS queue bound to the USB-connected printer. Updates queues in place.
#
# See README.md for how/why this works.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$REPO/driver"
DEST="/Library/Printers/Xerox/P3020"
PPD_SYS="/Library/Printers/PPDs/Contents/Resources/Xerox Phaser 3020"
QUEUE="${QUEUE:-Xerox_Phaser_3020}"

[ "$(uname)" = "Darwin" ] || { echo "This is for macOS only."; exit 1; }

if [ "${1:-}" = "--check" ]; then
  exec "$REPO/scripts/doctor.sh"
fi
[ "$#" -eq 0 ] || { echo "Usage: $0 [--check]"; exit 1; }
[[ "$QUEUE" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || { echo "Invalid QUEUE name."; exit 1; }
echo ">> macOS $(sw_vers -productVersion) ($(uname -m))"
for name in rastertosec prefilter commandtosec SCMS/libscmssc.dylib SCMS/P3020sc.cts Xerox_Phaser_3020.ppd; do
  [ -r "$DRIVER/$name" ] || { echo "Missing driver file: $name"; exit 1; }
done

# --- 1. Rosetta 2 (Apple Silicon only) -------------------------------------
# An actual Intel execution is reliable even when Rosetta's files/processes
# change between macOS releases or this shell itself runs under Rosetta.
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  if [ "$(uname -m)" = "arm64" ]; then
    echo ">> Installing Rosetta 2 (needed to run the Intel print filter)…"
    sudo softwareupdate --install-rosetta --agree-to-license
  fi
fi
/usr/bin/arch -x86_64 /usr/bin/true || { echo "Intel execution is unavailable on this macOS release."; exit 1; }

# The filter intentionally exits 1 without CUPS arguments. Check its usage
# message rather than masking all failures (including dyld/architecture errors).
probe="$(/usr/bin/arch -x86_64 "$DRIVER/rastertosec" </dev/null 2>&1 || true)"
case "$probe" in
  *"ERROR: rastertopcl job-id user title copies options [file]"*) ;;
  *) echo "The bundled filter cannot load: $probe"; exit 1 ;;
esac

# --- 2. Detect the printer's USB device URI (don't hardcode the serial) ----
echo ">> Looking for the Phaser 3020 on USB…"
if ! devices="$(lpinfo -v 2>&1)"; then
  echo "Cannot query the macOS printing service: $devices"
  exit 1
fi
uris="$(printf '%s\n' "$devices" | awk 'tolower($2) ~ /^usb:\/\/xerox\/phaser(%20| )?3020([?\/]|$)/ {print $2}')"
if [ -n "${URI:-}" ]; then
  printf '%s\n' "$uris" | grep -Fx -- "$URI" >/dev/null || { echo "URI must match a connected Phaser 3020 USB device."; exit 1; }
else
  [ "$(printf '%s\n' "$uris" | awk 'NF {n++} END {print n+0}')" -le 1 ] || {
    echo "Multiple printers found. Set URI to one of these and rerun:"; echo "$uris"; exit 1;
  }
  URI="$uris"
fi
if [ -z "${URI:-}" ]; then
  echo "!! Phaser 3020 not found on USB."
  echo "   Power it on, press a button to wake it, check the cable (plug straight into the Mac),"
  echo "   then re-run ./bootstrap.sh.  Current CUPS USB devices:"
  lpinfo -v 2>/dev/null | grep -i usb || echo "   (none)"
  exit 1
fi
echo ">> Found: $URI"

PPD="$(mktemp /private/tmp/phaser3020-ppd.XXXXXX)"
trap 'rm -f "$PPD"' EXIT
"$REPO/scripts/prepare-ppd.sh" > "$PPD"

# --- 3. Install the driver files where the PPD expects them ----------------
echo ">> Installing driver to $DEST (you'll be asked for your password)…"
sudo install -d -m 755 "$DEST/SCMS"
for filter in rastertosec prefilter commandtosec; do
  sudo install -m 755 "$DRIVER/$filter" "$DEST/$filter.bin"
  sudo install -m 755 "$REPO/scripts/filter-launcher.sh" "$DEST/$filter"
done
sudo install -m 755 "$DRIVER/SCMS/libscmssc.dylib" "$DEST/SCMS/libscmssc.dylib"
sudo install -m 644 "$DRIVER/SCMS/P3020sc.cts"     "$DEST/SCMS/P3020sc.cts"
sudo xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true   # clear "downloaded" flag

# PPD into the system repository too (lets the GUI "Add Printer" find it)
sudo install -d -m 755 "$(dirname "$PPD_SYS")"
sudo install -m 644 "$PPD" "$PPD_SYS"

# Verify the installed launcher before changing the queue.
probe="$("$DEST/rastertosec" </dev/null 2>&1 || true)"
case "$probe" in
  *"ERROR: rastertopcl job-id user title copies options [file]"*) ;;
  *) echo "Installed filter cannot load: $probe"; exit 1 ;;
esac

# --- 4. Create / update the CUPS queue without deleting queued jobs ---------
echo ">> Creating CUPS queue '$QUEUE'…"
sudo lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD" \
     -D "Xerox Phaser 3020 (SPL via Rosetta 2)" -L "USB"
sudo cupsenable "$QUEUE"
sudo cupsaccept "$QUEUE"

echo
echo "✅ Done. '$QUEUE' is installed and ready."
echo "   Test it:  ./scripts/wake-and-print.sh"
echo "   Or print from any app (⌘P) and choose 'Xerox Phaser 3020'."
