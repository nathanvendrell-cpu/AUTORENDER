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
inputs=( "$project"/Sources/RenduBar/*.swift "$project/Scripts/UIHarness50.swift" "$project/Scripts/build-ui-harness50.sh" )
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/before.sha256"
swiftc -O -D AUTORENDER_UI_HARNESS -framework AppKit -framework SwiftUI -framework ImageIO \
  "$project"/Sources/RenduBar/*.swift "$project/Scripts/UIHarness50.swift" -o "$bundle/Contents/MacOS/UIHarness50"
python3 - "$bundle/Contents/Info.plist" "$project/Evidence" <<'PY'
import plistlib,sys
p={'CFBundleDisplayName':'AUTORENDER UI — 50 JOBS SIMULÉS','CFBundleName':'AUTORENDER UI Harness50','CFBundleExecutable':'UIHarness50',
   'CFBundleIdentifier':'fr.robtech.autorender.ui-harness50','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.5.0',
   'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'LSUIElement':False,'UIHarnessReportDirectory':sys.argv[2]}
with open(sys.argv[1],'wb') as f:plistlib.dump(p,f)
PY
(cd "$project"; shasum -a 256 "${inputs[@]#"$project/"}") > "$staging/after.sha256"
cmp -s "$staging/before.sha256" "$staging/after.sha256" || { echo 'Harness source changed: rejected.' >&2; exit 1; }
cp "$staging/before.sha256" "$bundle/Contents/Resources/harness-source-manifest.sha256"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
mv "$bundle" "$app"
echo "$app"
