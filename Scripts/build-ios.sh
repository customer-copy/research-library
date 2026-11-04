#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TASK_IOS_BUILD="${RESEARCH_LIBRARY_IOS_DERIVED_DATA:-${TMPDIR:-/private/tmp}/researchlibrary-ios-build}"
xcodebuild -project ResearchLibrary.xcodeproj -scheme 'Research Library Capture' -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath "$TASK_IOS_BUILD" CODE_SIGNING_ALLOWED=NO ARCHS="$(uname -m)" clean build
mkdir -p Build
ditto "$TASK_IOS_BUILD/Build/Products/Release-iphonesimulator/Research Library Capture.app" 'Build/Research Library Capture.app'
printf 'Built %s/Build/Research Library Capture.app (Simulator)\n' "$PWD"
