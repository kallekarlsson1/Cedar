#!/bin/bash
# Builds Sift.app and installs it in ~/Applications.  Usage: ./build.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/Sift.app"

(cd "$here/engine" && uv sync --quiet)
(cd "$here/app" && swift build -c release)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/app/.build/release/Sift" "$app/Contents/MacOS/Sift"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.kallekarlsson1.sift</string>
    <key>CFBundleName</key><string>Sift</string>
    <key>CFBundleDisplayName</key><string>Sift</string>
    <key>CFBundleExecutable</key><string>Sift</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>SiftEngineDir</key><string>$here/engine</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Installed $app"
