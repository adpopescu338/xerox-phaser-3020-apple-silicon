#!/usr/bin/env bash
# Exercise the real PDF -> raster -> SPL pipeline without installing or printing.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(uname)" = Darwin ] || { echo "This check requires macOS."; exit 1; }
STAGE="$(mktemp -d /private/tmp/phaser3020-pipeline.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
for filter in rastertosec prefilter commandtosec; do
  cp "$REPO/driver/$filter" "$STAGE/$filter.bin"
  cp "$REPO/scripts/filter-launcher.sh" "$STAGE/$filter"
  chmod 755 "$STAGE/$filter" "$STAGE/$filter.bin"
done
cp -R "$REPO/driver/SCMS" "$STAGE/SCMS"
"$REPO/scripts/prepare-ppd.sh" | sed "s|/Library/Printers/Xerox/P3020|$STAGE|g" > "$STAGE/printer.ppd"
# Staged filters belong to the current user; the installer uses root-owned files.
if ! cupstestppd -q -I filters "$STAGE/printer.ppd"; then
  cupstestppd -I filters "$STAGE/printer.ppd" >&2
  exit 1
fi
if ! /usr/sbin/cupsfilter -e -p "$STAGE/printer.ppd" \
    -m printer/Xerox_Phaser_3020 "$REPO/test/test-page.pdf" \
    > "$STAGE/output.spl" 2> "$STAGE/render.log"; then
  cat "$STAGE/render.log" >&2
  exit 1
fi
[ -s "$STAGE/output.spl" ] || { echo "FAIL: no printer data generated."; exit 1; }
LC_ALL=C grep -a -q '@PJL' "$STAGE/output.spl" || { echo "FAIL: missing printer job header."; exit 1; }
echo "PASS: PDF -> raster -> SPL ($(wc -c < "$STAGE/output.spl" | tr -d ' ') bytes); no job sent."
