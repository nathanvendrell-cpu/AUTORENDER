#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${AUTORENDER_HARNESS_APP:-$project/Build/QA/AUTORENDER-UI-Harness50.app}"
if [ -e "$app" ]; then echo 'Harness destination exists; choose a fresh path.' >&2; exit 1; fi
mkdir -p "$project/Build/QA" "$(dirname "$app")"
staging="$(mktemp -d "$project/Build/QA/UIHarness50-build.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bundle="$staging/AUTORENDER-UI-Harness50.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# One recursive inventory feeds both compilation and the source manifest.
python3 "$project/Scripts/swift-sources.py" "$project/Sources/RenduBar" > "$staging/swift-before.txt"
swift_sources=()
while IFS= read -r source; do swift_sources+=( "$source" ); done < "$staging/swift-before.txt"
python_helpers=( "$project/Sources/RenduBar/Infrastructure/shadow_collector.py" "$project/Sources/RenduBar/Infrastructure/shadow_run_contract.py" "$project/Sources/RenduBar/Infrastructure/shadow_run_observer.py" "$project/Sources/RenduBar/Infrastructure/native_script_contract.py" )
inputs=( "${swift_sources[@]}" "$project/Scripts/swift-sources.py" "$project/Scripts/UIHarness50.swift" "$project/Scripts/build-ui-harness50.sh" "${python_helpers[@]}" "$project/Scripts/check-python-resources.py" "$project/Resources/Info.plist" )
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/before.sha256"
swiftc -O -D AUTORENDER_UI_HARNESS -framework AppKit -framework SwiftUI -framework ImageIO \
  "${swift_sources[@]}" "$project/Scripts/UIHarness50.swift" -o "$bundle/Contents/MacOS/UIHarness50"
for helper in "${python_helpers[@]}"; do cp "$helper" "$bundle/Contents/Resources/"; done
python3 - "$bundle/Contents/Info.plist" "$project/Evidence" "$project/Resources/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[3],'rb') as f:version=plistlib.load(f)
p={'CFBundleDisplayName':'AUTORENDER UI — 50 JOBS SIMULÉS','CFBundleName':'AUTORENDER UI Harness50','CFBundleExecutable':'UIHarness50',
   'CFBundleIdentifier':'fr.robtech.autorender.ui-harness50','CFBundlePackageType':'APPL','CFBundleVersion':version['CFBundleVersion'],'CFBundleShortVersionString':version['CFBundleShortVersionString'],
   'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'LSUIElement':False,'UIHarnessReportDirectory':sys.argv[2]}
with open(sys.argv[1],'wb') as f:plistlib.dump(p,f)
PY
python3 "$project/Scripts/swift-sources.py" "$project/Sources/RenduBar" > "$staging/swift-after.txt"
cmp -s "$staging/swift-before.txt" "$staging/swift-after.txt" || { echo 'Swift source inventory changed: candidate rejected.' >&2; exit 1; }
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/after.sha256"
cmp -s "$staging/before.sha256" "$staging/after.sha256" || { echo 'Harness source changed: rejected.' >&2; exit 1; }
cp "$staging/before.sha256" "$bundle/Contents/Resources/harness-source-manifest.sha256"
codesign --force --sign - "$bundle"
python3 -B "$project/Scripts/check-python-resources.py" "$bundle/Contents/Resources"
plutil -lint "$bundle/Contents/Info.plist"
codesign --verify --deep --strict "$bundle"
mv "$bundle" "$app"
echo "$app"
