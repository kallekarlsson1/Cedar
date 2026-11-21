#!/bin/bash
# Makes the download for a release: dist/Cedar-VERSION.dmg (the app and a shortcut to Applications).
#   scripts/release.sh 0.1.0             builds the disk image
#   scripts/release.sh 0.1.0 --publish   also tags v0.1.0 and uploads it to the repository's GitHub Releases
# The quality check has to pass first.
set -euo pipefail
version="${1:?usage: scripts/release.sh VERSION [--publish]}"
here="$(cd "$(dirname "$0")/.." && pwd)"
dist="$here/dist"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

"$here/scripts/check.sh" || { echo "the quality check failed: not releasing"; exit 1; }
VERSION="$version" "$here/build.sh" "$stage" >/dev/null
# Nothing in the app may depend on this Mac: only system libraries.
if otool -L "$stage/Cedar.app/Contents/MacOS/Cedar" | tail -n +2 | grep -v -E "^\s*(/usr/lib/|/System/)" ; then
    echo "the app links to libraries outside macOS: not releasing"; exit 1
fi
ln -s /Applications "$stage/Applications"
mkdir -p "$dist"
dmg="$dist/Cedar-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Cedar $version" -srcfolder "$stage" -format UDZO "$dmg"
echo "$dmg  ($(du -h "$dmg" | cut -f1))"
shasum -a 256 "$dmg" | cut -d" " -f1 > "$dmg.sha256"

if [ "${2:-}" = "--publish" ]; then
    git -C "$here" diff --quiet || { echo "commit your changes first"; exit 1; }
    gh release create "v$version" "$dmg" "$dmg.sha256" --title "Cedar $version" --generate-notes
fi
