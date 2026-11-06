#!/usr/bin/env bash
# Builds Team Car into an app bundle's Contents/Helpers. Usage: scripts/build-teamcar.sh path/to/Domestique.app
# The app starts it from there (see RaceRadioKit's LocalTeamCar). Re-sign the bundle afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(cd "$(dirname "${1:?usage: scripts/build-teamcar.sh path/to/Domestique.app}")" && pwd)/$(basename "$1")"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
mkdir -p "$APP/Contents/Helpers"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go -C teamcar build -trimpath \
  -ldflags "-s -w -X main.version=$VERSION" -o "$APP/Contents/Helpers/teamcar" ./cmd/teamcar
echo "Built $APP/Contents/Helpers/teamcar ($VERSION)"
