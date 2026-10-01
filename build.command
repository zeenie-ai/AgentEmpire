#!/bin/sh
# Builds Aurelhaven for this Mac. Double-click this file in Finder (or right-click it and choose
# Open the first time, if macOS says it is from an unidentified developer).
cd "$(dirname "$0")" || exit 1
sh ./build.sh
status=$?
if [ "$status" -eq 0 ]; then
  open dist
fi
echo
echo "You can close this window."
exit "$status"
