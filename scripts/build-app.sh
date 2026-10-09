#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Build requires macOS 14+ and Xcode command-line tools." >&2
  exit 1
fi
swift test
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/dist/LinguaFloat.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/LinguaFloat" "$app_dir/Contents/MacOS/LinguaFloat"
cp Info.plist "$app_dir/Contents/Info.plist"
# Finder metadata copied into the bundle makes codesign refuse with "resource fork, Finder information, or similar detritus".
xattr -cr "$app_dir"
# Ad-hoc signatures pin privacy grants (Accessibility, Screen Recording) to one build's cdhash,
# so every rebuild silently loses them. Prefer a stable Apple Development identity when present.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
codesign --force --sign "${identity:--}" "$app_dir"
echo "Built: $app_dir"
if [[ -z "$identity" ]]; then
  echo "WARNING: ad-hoc signed. Privacy permissions must be re-granted after every rebuild." >&2
else
  echo "Signed with: $identity"
fi
