#!/bin/bash
set -euo pipefail
TASK_EXTENSION_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$TASK_EXTENSION_DIR/../Scripts/install-chrome-extension.py"
printf '\nSetup complete. You may close this window.\n'
