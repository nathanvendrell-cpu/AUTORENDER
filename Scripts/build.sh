#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sparkle="$(python3 -B "$project/Scripts/sparkle-dependency.py")"
minimum_os="$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$project/Resources/Info.plist")"
target="$(uname -m)-apple-macosx$minimum_os"
app="${AUTORENDER_BUILD_APP:-${RENDUBAR_BUILD_APP:-$project/Build/Products.noindex/AUTORENDER.app}}"
if [ -e "$app" ]; then
  echo 'Destination already exists; choose a fresh AUTORENDER_BUILD_APP path to preserve previous builds.' >&2
  exit 1
fi
mkdir -p "$project/Build/Products.noindex" "$(dirname "$app")"
staging="$(mktemp -d "$project/Build/Products.noindex/AUTORENDER-build.XXXXXX")"
cleanup() { rm -rf -- "$staging"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
candidate="$staging/AUTORENDER.app"
mkdir -p "${candidate}/Contents/Frameworks"
ditto "$sparkle/Sparkle.framework" "${candidate}/Contents/Frameworks/Sparkle.framework"
codesign --verify --deep --strict "${candidate}/Contents/Frameworks/Sparkle.framework"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
# One recursive inventory feeds both compilation and the source manifest.
python3 "$project/Scripts/swift-sources.py" "$project/Sources/RenduBar" > "$staging/swift-before.txt"
swift_sources=()
while IFS= read -r source; do swift_sources+=( "$source" ); done < "$staging/swift-before.txt"
python_helpers=( "$project/Sources/RenduBar/Infrastructure/shadow_collector.py" "$project/Sources/RenduBar/Infrastructure/shadow_run_contract.py" "$project/Sources/RenduBar/Infrastructure/shadow_run_observer.py" "$project/Sources/RenduBar/Infrastructure/native_script_contract.py" "$project/Sources/RenduBar/Infrastructure/standard_render_observation.py" "$project/Sources/RenduBar/Infrastructure/render_library_transport.py" )
powershell_helpers=( "$project/Sources/RenduBar/Infrastructure/shadow_process_observer.ps1" "$project/Sources/RenduBar/Infrastructure/remote_library.ps1" )
blender_helpers=( "$project/Sources/RenduBar/Infrastructure/blender_render_relay.py" )
inputs=( "$project/Resources/Sparkle.lock.json" "$project/Resources/Sparkle-LICENSE.txt" "$project/Scripts/sparkle-dependency.py" "${swift_sources[@]}" "$project/Scripts/swift-sources.py" "${python_helpers[@]}" "${powershell_helpers[@]}" "${blender_helpers[@]}" "$project/Scripts/check-python-resources.py" "$project/Resources/Info.plist" "$project/Scripts/ExportIcon.swift" "$project/Scripts/build.sh" )
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/source-before.sha256"
swiftc -j 2 -O -target "$target" -framework AppKit -framework SwiftUI -framework ImageIO -F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${swift_sources[@]}" -o "$candidate/Contents/MacOS/RenduBar"
cp "$project/Resources/Info.plist" "$candidate/Contents/Info.plist"
cp "$project/Resources/Sparkle-LICENSE.txt" "$candidate/Contents/Resources/Sparkle-LICENSE.txt"
for helper in "${python_helpers[@]}" "${powershell_helpers[@]}" "${blender_helpers[@]}"; do cp "$helper" "$candidate/Contents/Resources/"; done
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
swiftc -j 2 -O -target "$target" -framework AppKit "$project/Sources/RenduBar/UI/Logo.swift" \
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
python3 "$project/Scripts/swift-sources.py" "$project/Sources/RenduBar" > "$staging/swift-after.txt"
cmp -s "$staging/swift-before.txt" "$staging/swift-after.txt" || { echo 'Swift source inventory changed: candidate rejected.' >&2; exit 1; }
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/source-after.sha256"
if ! cmp -s "$staging/source-before.sha256" "$staging/source-after.sha256"; then
  echo 'Source changed during build; candidate rejected.' >&2
  exit 1
fi
cp "$staging/source-before.sha256" "$candidate/Contents/Resources/source-manifest.sha256"
# The manifest is a bundled resource, so sign the final resource tree again.
codesign --force --sign - "$candidate"
python3 -B "$project/Scripts/check-python-resources.py" "$candidate/Contents/Resources"
codesign --verify --deep --strict "$candidate"
mv "$candidate" "$app"
echo "$app"
