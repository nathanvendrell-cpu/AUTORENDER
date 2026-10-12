#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${AUTORENDER_BUILD_APP:-${RENDUBAR_BUILD_APP:-$project/Build/AUTORENDER.app}}"
if [ -e "$app" ]; then
  echo 'Destination already exists; choose a fresh AUTORENDER_BUILD_APP path to preserve previous builds.' >&2
  exit 1
fi
mkdir -p "$project/Build" "$(dirname "$app")"
staging="$(mktemp -d "$project/Build/AUTORENDER-build.XXXXXX")"
cleanup() { rm -rf -- "$staging"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
candidate="$staging/AUTORENDER.app"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
inputs=( "$project"/Sources/RenduBar/*.swift "$project/Sources/RenduBar/shadow_collector.py" "$project/Resources/Info.plist" "$project/Scripts/ExportIcon.swift" "$project/Scripts/build.sh" )
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/source-before.sha256"
swiftc -O -framework AppKit -framework SwiftUI -framework ImageIO \
  "$project"/Sources/RenduBar/*.swift -o "$candidate/Contents/MacOS/RenduBar"
cp "$project/Resources/Info.plist" "$candidate/Contents/Info.plist"
cp "$project/Sources/RenduBar/shadow_collector.py" "$candidate/Contents/Resources/shadow_collector.py"
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
swiftc -O -framework AppKit "$project/Sources/RenduBar/Logo.swift" \
  "$project/Scripts/ExportIcon.swift" -o "$staging/ExportIcon"
"$staging/ExportIcon" "$staging/icon-1024.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$staging/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
done
for pair in '16 32' '32 64' '128 256' '256 512' '512 1024'; do
  read -r size pixels <<< "$pair"
  sips -z "$pixels" "$pixels" "$staging/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$candidate/Contents/Resources/AppIcon.icns"
plutil -lint "$candidate/Contents/Info.plist"
codesign --force --sign - "$candidate"
codesign --verify --strict "$candidate"
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/source-after.sha256"
if ! cmp -s "$staging/source-before.sha256" "$staging/source-after.sha256"; then
  echo 'Source changed during build; candidate rejected.' >&2
  exit 1
fi
cp "$staging/source-before.sha256" "$candidate/Contents/Resources/source-manifest.sha256"
# The manifest is a bundled resource, so sign the final resource tree again.
codesign --force --sign - "$candidate"
codesign --verify --strict "$candidate"
mv "$candidate" "$app"
echo "$app"
