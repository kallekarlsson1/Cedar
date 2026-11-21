#!/bin/bash
# Builds Cedar.app.   ./build.sh            installs it in ~/Applications
#                     ./build.sh DIR        puts it in DIR instead (scripts/release.sh uses this)
# VERSION=1.2.3 sets the version written into the app (default: 0.1.0).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$HOME/Applications}"
app="$dest/Cedar.app"
version="${VERSION:-0.1.0}"

[ -f "$here/app/Vendor/llama/lib/libllama.a" ] || "$here/scripts/build-llama.sh"   # compiles llama.cpp the first time
# -file-prefix-map: the binary records source paths relative to the project, not this Mac's folders.
(cd "$here/app" && swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$here=." -Xswiftc -debug-prefix-map -Xswiftc "$here=.")

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/app/.build/release/Cedar" "$app/Contents/MacOS/Cedar"
strip -x "$app/Contents/MacOS/Cedar" 2>/dev/null || true      # no local symbols or debug paths in the shipped binary
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
codesign --force --sign - "$app"     # ad hoc: there is no Apple Developer signature
echo "Installed $app"
