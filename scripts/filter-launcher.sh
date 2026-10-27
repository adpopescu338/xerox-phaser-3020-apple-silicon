#!/bin/sh
# CUPS may reject a universal Intel/i386 executable on Apple Silicon before
# Rosetta is selected. Keep the PPD paths and explicitly select its 64-bit slice.
exec /usr/bin/arch -x86_64 "$0.bin" "$@"
