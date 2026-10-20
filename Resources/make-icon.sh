#!/usr/bin/env bash
# make-icon.sh — rebuilds Resources/AppIcon.icns from make-icon.swift.
# Draws a 1024 PNG, scales it to every size macOS wants, and packs them with iconutil.
# Run only when the icon design changes; build.sh just copies the finished .icns.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift make-icon.swift "$WORK/icon-1024.png"

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Wrote $(pwd)/AppIcon.icns"
