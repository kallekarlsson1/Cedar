#!/bin/bash
# Builds Cedar.app into ~/Applications, or into the directory given as the first argument.
# Set VERSION to choose the version number (default 0.1.0).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$HOME/Applications}"
app="$dest/Cedar.app"
version="${VERSION:-0.1.0}"

[ -f "$here/app/Vendor/llama/lib/libllama.a" ] || "$here/scripts/build-llama.sh"
# Keep absolute source paths out of the binary.
(cd "$here/app" && swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$here=." -Xswiftc -debug-prefix-map -Xswiftc "$here=.")

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/app/.build/release/Cedar" "$app/Contents/MacOS/Cedar"
strip -x "$app/Contents/MacOS/Cedar" 2>/dev/null || true
cp "$here/app/Resources/AppIcon.icns" "$here/app/Resources/Acknowledgements.txt" "$here/LICENSE" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.kallekarlsson1.cedar</string>
    <key>CFBundleName</key><string>Cedar</string>
    <key>CFBundleDisplayName</key><string>Cedar</string>
    <key>CFBundleExecutable</key><string>Cedar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"   # ad hoc signature
echo "Installed $app"
