#!/usr/bin/env bash
# Builds Domestique.app from Domestique.xcodeproj into ./build. Usage: scripts/build-app.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
case "$CONFIG" in debug) CONFIG=Debug ;; release) CONFIG=Release ;; esac
xcodebuild -project Domestique.xcodeproj -scheme Domestique -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation -quiet build
rm -rf build/Domestique.app
cp -R "build/DerivedData/Build/Products/$CONFIG/Domestique.app" build/Domestique.app
echo "Built build/Domestique.app ($CONFIG)"
