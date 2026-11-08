#!/usr/bin/env bash
# Builds release archives of the server into dist/:
#   dist/domestique_<version>_<os>_<arch>.tar.gz  (the domestique binary, README.md, deploy/)
#   dist/domestique_<version>_<os>_<arch>.tar.gz.sha256
# Usage: scripts/build-server-dist.sh [version]   (default: git describe)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
DIST="$ROOT/dist"
TARGETS=(linux/amd64 linux/arm64 darwin/arm64)

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

mkdir -p "$DIST"
export COPYFILE_DISABLE=1 # no macOS ._ metadata files in the archives
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for target in "${TARGETS[@]}"; do
  os="${target%/*}" arch="${target#*/}"
  name="domestique_${VERSION}_${os}_${arch}"
  dir="$STAGE/$name"
  mkdir -p "$dir"
  CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go -C server build -trimpath \
    -ldflags "-s -w -X main.version=$VERSION" -o "$dir/domestique" ./cmd/domestique
  cp server/README.md "$dir/"
  cp -R server/deploy "$dir/deploy"
  tar -C "$STAGE" -czf "$DIST/$name.tar.gz" "$name"
  (cd "$DIST" && sha256 "$name.tar.gz" > "$name.tar.gz.sha256")
  echo "built dist/$name.tar.gz ($(cut -c1-16 "$DIST/$name.tar.gz.sha256")…)"
done
