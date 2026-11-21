#!/bin/bash
# Builds Cedar.app and installs it in ~/Applications.  Usage: ./build.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/Cedar.app"

(cd "$here/engine" && CMAKE_ARGS="-DGGML_METAL=on" uv sync --quiet)   # compiles llama.cpp the first time
(cd "$here/app" && swift build -c release)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/app/.build/release/Cedar" "$app/Contents/MacOS/Cedar"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.kallekarlsson1.cedar</string>
    <key>CFBundleName</key><string>Cedar</string>
    <key>CFBundleDisplayName</key><string>Cedar</string>
    <key>CFBundleExecutable</key><string>Cedar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CedarEngineDir</key><string>$here/engine</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Installed $app"
