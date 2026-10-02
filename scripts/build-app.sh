#!/usr/bin/env bash
# Builds "Merry.app" with the Command Line Tools alone (no Xcode).
#
#   scripts/build-app.sh             build into dist/
#   scripts/build-app.sh --install   also copy to Applications and open it
#
# The app is signed ad hoc, which macOS ties to this exact build: after a
# rebuild it may ask for its permissions again.
set -euo pipefail
cd "$(dirname "$0")/.."

name="Merry"
app="dist/$name.app"

swift build -c release --product Merry
bin="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Merry" "$app/Contents/MacOS/Merry"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp Sources/MerryUI/Resources/PixelifySans.ttf "$app/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES "$app/Contents/Resources/"

# The icon, in the sizes macOS asks for.
iconset="$(mktemp -d)/icon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Sources/MerryUI/Resources/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Sources/MerryUI/Resources/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/icon.icns"

codesign --force --sign - --identifier app.merry.pet "$app"
codesign --verify --strict "$app"
echo "built $PWD/$app"

if [ "${1:-}" = "--install" ]; then
  target="/Applications/$name.app"
  [ -w /Applications ] || { target="$HOME/Applications/$name.app"; mkdir -p "$HOME/Applications"; }
  # Stop a running copy before its files are replaced.
  pkill -f "$target/Contents/MacOS/Merry" 2>/dev/null || true
  sleep 0.5
  rm -rf "$target"
  ditto "$app" "$target"
  open "$target"
  echo "installed at $target and running. Press ⌘⇧Space to open it."
fi
