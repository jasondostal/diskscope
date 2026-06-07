#!/usr/bin/env bash
# Render the master PNG and assemble it into Packaging/AppIcon.icns (all required sizes).
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="Packaging/icon-1024.png"
ICONSET="Packaging/AppIcon.iconset"
ICNS="Packaging/AppIcon.icns"

echo "→ rendering master icon"
swift Scripts/render-icon.swift "$MASTER"

echo "→ building iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# name → pixel size for the standard macOS iconset.
for spec in \
  "icon_16x16:16" "icon_16x16@2x:32" \
  "icon_32x32:32" "icon_32x32@2x:64" \
  "icon_128x128:128" "icon_128x128@2x:256" \
  "icon_256x256:256" "icon_256x256@2x:512" \
  "icon_512x512:512" "icon_512x512@2x:1024"; do
  name="${spec%%:*}"; px="${spec##*:}"
  sips -z "$px" "$px" "$MASTER" --out "$ICONSET/${name}.png" >/dev/null
done

echo "→ iconutil → $ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"
echo "✓ $ICNS"
