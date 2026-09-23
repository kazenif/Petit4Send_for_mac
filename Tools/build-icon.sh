#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
iconset="$PWD/Assets/Petit4SendMac.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/Petit4SendMac-icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/Petit4SendMac-icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# The icns lives with the executable target's resources so that Bundle.module
# can reach it: Xcode builds this package as a bare binary with no Info.plist,
# so the app has to install its Dock icon itself.
mkdir -p Sources/Petit4SendMac/Resources
iconutil -c icns "$iconset" -o Sources/Petit4SendMac/Resources/Petit4SendMac.icns
