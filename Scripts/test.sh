#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_BUILD_DIR="${TMPDIR:-/private/tmp}/researchlibrary-build"
mkdir -p .build/cache .build/security .build/config
export CLANG_MODULE_CACHE_PATH="$TASK_BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_BUILD_DIR/module-cache"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
TASK_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
TASK_PLUGIN_DIR="$TASK_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
if [[ ! -d "$TASK_PLUGIN_DIR" ]]; then TASK_PLUGIN_DIR="$TASK_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"; fi
TASK_FLAGS=()
if [[ -d "$TASK_PLUGIN_DIR" ]]; then TASK_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$TASK_PLUGIN_DIR"); fi
swift test --disable-sandbox --scratch-path "$TASK_BUILD_DIR" --cache-path "$PWD/.build/cache" --security-path "$PWD/.build/security" --config-path "$PWD/.build/config" --disable-xctest ${TASK_FLAGS[@]+"${TASK_FLAGS[@]}"}
