#!/usr/bin/env bash
# Omit references to legacy GUI plugins/utilities/icons we do not distribute.
# Leave the vendor original intact so its published checksum remains valid.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed '/^\*APDialogExtension:/d; /^\*APPrinterUtilityPath:/d; /^\*APPrinterIconPath:/d' \
  "$REPO/driver/Xerox_Phaser_3020.ppd"
