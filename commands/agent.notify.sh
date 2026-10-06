#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

NOTIFY_SCRIPT="${SCRIPT_DIR}/../lib/agent-notify.mjs"
PLATFORM="$(platform_id)"

case "$PLATFORM" in
    wsl|git-bash) ;;
    *)
        echo "Error: 'lazy agent.notify' is not available on $(platform_label "$PLATFORM")."
        echo "       This implementation uses the Windows text-to-speech engine."
        exit 1
        ;;
esac

if ! command -v node >/dev/null 2>&1; then
    echo "Error: lazy agent.notify requires Node.js."
    exit 1
fi

# Help and uninstall do not need a working Windows bridge. Keeping uninstall
# available matters if WSL interop breaks after the hook was installed.
case "${1:-}" in
    -h|--help|--uninstall) exec node "$NOTIFY_SCRIPT" "$@" ;;
esac

if [ "$PLATFORM" = "wsl" ] && ! wsl_interop_ok; then
    echo "Error: WSL cannot currently start Windows executables."
    echo "       Re-enable WSL interop, then run this command again."
    wsl_interop_permanent_hint
    exit 1
fi

POWERSHELL_EXE="$(win_exe_path powershell.exe || true)"
if [ -z "$POWERSHELL_EXE" ]; then
    echo "Error: powershell.exe was not found."
    echo "       Windows PowerShell is required for the built-in speech engine."
    exit 1
fi

export LAZY_AGENT_NOTIFY_POWERSHELL="$POWERSHELL_EXE"
exec node "$NOTIFY_SCRIPT" "$@"
