#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/../lib/agent-sync.mjs"

if ! command -v node >/dev/null 2>&1; then
    echo "Error: lazy agent.sync requires Node.js."
    exit 1
fi

exec node "$SYNC_SCRIPT" "$@"
