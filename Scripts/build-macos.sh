#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_BUILD_DIR="${TMPDIR:-/private/tmp}/researchlibrary-build"
TASK_APP_DIR="$PWD/Build/Research Library.app"
mkdir -p .build/cache .build/security .build/config
export CLANG_MODULE_CACHE_PATH="$TASK_BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_BUILD_DIR/module-cache"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
 export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR/Platforms/iPhoneOS.platform" ]]; then
 xcodebuild -project ResearchLibrary.xcodeproj -scheme 'Research Library' -configuration Release -destination 'platform=macOS' -derivedDataPath "$TASK_BUILD_DIR/xcode-release" CODE_SIGNING_ALLOWED=NO ARCHS="$(uname -m)" clean build
 mkdir -p Build
 ditto "$TASK_BUILD_DIR/xcode-release/Build/Products/Release/Research Library.app" "$TASK_APP_DIR"
else
 swift build --disable-sandbox --scratch-path "$TASK_BUILD_DIR" --cache-path "$PWD/.build/cache" --security-path "$PWD/.build/security" --config-path "$PWD/.build/config" -c release
 TASK_BIN_DIR="$(swift build --disable-sandbox --scratch-path "$TASK_BUILD_DIR" --cache-path "$PWD/.build/cache" --security-path "$PWD/.build/security" --config-path "$PWD/.build/config" -c release --show-bin-path)"
 mkdir -p "$TASK_APP_DIR/Contents/MacOS" "$TASK_APP_DIR/Contents/Resources"
 cp "$TASK_BIN_DIR/ResearchLibrary" "$TASK_APP_DIR/Contents/MacOS/ResearchLibrary"
 cp Apple/macOS-Info.plist "$TASK_APP_DIR/Contents/Info.plist"
 /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ResearchLibrary' "$TASK_APP_DIR/Contents/Info.plist"
 /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.researchlibrary.mac' "$TASK_APP_DIR/Contents/Info.plist"
fi
xattr -cr "$TASK_APP_DIR"
if [[ -d "$TASK_APP_DIR/Contents/PlugIns/Save to Research Library.appex" ]]; then
 codesign --force --sign - --entitlements Apple/SafariExtension/Safari.entitlements "$TASK_APP_DIR/Contents/PlugIns/Save to Research Library.appex"
fi
codesign --force --sign - "$TASK_APP_DIR"
printf 'Built %s\n' "$TASK_APP_DIR"
