#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app="$PWD/dist/Petit4Send.app"
./Tools/build-icon.sh
previous_build=0
if [[ -f "$app/Contents/Info.plist" ]]; then
    previous_build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || echo 0)
fi
next_build=$((previous_build + 1))
# A content-specific resource name avoids reuse of an earlier cached icon.
icns=Sources/Petit4SendMac/Resources/Petit4SendMac.icns
icon_hash=$(shasum -a 256 "$icns" | cut -c 1-12)
icon_name="Petit4SendMac-${icon_hash}.icns"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Drop icons from earlier builds so only the current one ships. The (N) glob
# qualifier is required: on a first build nothing matches, and zsh would
# otherwise abort the script rather than expand to nothing.
rm -f "$app/Contents/Resources"/*.icns(N)
cp "$icns" "$app/Contents/Resources/$icon_name"
# Bundle.module traps when its resource bundle is missing, and the app reads the
# icon through it, so the bundle has to ship alongside Info.plist's copy.
rm -rf "$app/Contents/Resources/Petit4Send_Petit4SendMac.bundle"
cp -R "$binary_dir/Petit4Send_Petit4SendMac.bundle" "$app/Contents/Resources/"
cp "$binary_dir/Petit4SendMac" "$app/Contents/MacOS/Petit4SendMac"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Petit4SendMac</string>
<key>CFBundleIdentifier</key><string>local.petit4send.mac</string>
<key>CFBundleName</key><string>Petit4Send</string>
<key>CFBundleDisplayName</key><string>Petit4Send</string>
<key>CFBundleIconFile</key><string>Petit4SendMac.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -replace CFBundleIconFile -string "$icon_name" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$next_build" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
# Updating files inside a bundle does not update the bundle directory's mtime.
touch "$app"
registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$registrar" ]]; then
    "$registrar" -f "$app"
fi
echo "$app"
