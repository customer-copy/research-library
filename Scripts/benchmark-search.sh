#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
  printf 'Usage: %s /path/to/index.sqlite\n' "$0" >&2
  exit 2
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_SOURCE_INDEX="$1"
TASK_BENCH_ROOT=$(mktemp -d "${TMPDIR:-/private/tmp}/researchlibrary-search-benchmark.XXXXXX")
trap 'rm -rf "$TASK_BENCH_ROOT"' EXIT
TASK_COPY_INDEX="$TASK_BENCH_ROOT/index.sqlite"
python3 - "$TASK_SOURCE_INDEX" "$TASK_COPY_INDEX" <<'PY'
import sqlite3,sys
from pathlib import Path
source=sqlite3.connect(Path(sys.argv[1]).resolve().as_uri()+'?mode=ro',uri=True)
destination=sqlite3.connect(sys.argv[2])
try:
    source.backup(destination)
finally:
    destination.close()
    source.close()
PY
TASK_BUILD_ROOT="${TMPDIR:-/private/tmp}/researchlibrary-search-benchmark-build"
xcrun swift build --scratch-path "$TASK_BUILD_ROOT" --product ResearchLibraryTool
TASK_BIN_ROOT=$(xcrun swift build --scratch-path "$TASK_BUILD_ROOT" --show-bin-path)
mkdir -p Build
"$TASK_BIN_ROOT/ResearchLibraryTool" benchmark-search "$TASK_COPY_INDEX" "$PWD/Build/Search performance comparison.json" --migrate-copy
