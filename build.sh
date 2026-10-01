#!/bin/sh
# Builds Aurelhaven for this computer (Linux or macOS). Run it in a terminal: ./build.sh
# It downloads Godot (the game engine) the first time, then builds the game into dist/.
set -e
cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1; then
  echo "Aurelhaven needs Node.js to build."
  echo "Install the LTS version from https://nodejs.org and run ./build.sh again."
  exit 1
fi

node scripts/setup.mjs
node scripts/package-release.mjs --unpacked

echo
echo "Done. Your game is in the dist folder."
