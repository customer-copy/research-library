#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p Build
export RESEARCH_LIBRARY_BENCHMARK_REPORT="$PWD/Build/Reliability performance baseline.json"
xcrun swift test --scratch-path "${TMPDIR:-/private/tmp}/researchlibrary-hardening-tests" --filter CoreTests.testReconciliationAndReaderPerformanceBaseline
