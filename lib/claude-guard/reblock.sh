#!/bin/bash
# Installed by `lazy claude.guard` as <guard-dir>/claude-reblock.
#
#   claude-reblock       arm the kill switch (always locks)
#   claude-reblock -q    re-assert it quietly: lock only if the flag says it
#                        should be locked and no claude-run session is live.
#                        Safe to call from a shell rc file on every new shell.
#
# The -q mode exists because Claude Code is a TUI and must run in the
# foreground, and bash defers traps while a foreground child runs. A session
# killed with SIGKILL therefore never reaches its cleanup trap, which would
# leave the executable unlocked and the kill switch silently off.
#
# Do not edit this copy by hand; re-run `lazy claude.guard`.

set -u

GUARD_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-guard-common.sh"

if [ ! -r "$GUARD_LIB" ]; then
    echo "Error: guard library missing -> $GUARD_LIB" >&2
    echo "       Re-install it with: lazy claude.guard" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$GUARD_LIB"

QUIET=0
case "${1:-}" in
    -q|--quiet) QUIET=1 ;;
    "") ;;
    -h|--help)
        echo "Usage: claude-reblock [-q]"
        echo "  (no flag)  arm the Claude Code kill switch"
        echo "  -q         re-assert it quietly, skipping live claude-run sessions"
        exit 0
        ;;
    *)
        echo "Error: unknown option -> $1" >&2
        exit 1
        ;;
esac

if [ "$QUIET" -eq 1 ]; then
    cg_is_disabled || exit 0      # the kill switch is off on purpose
    cg_live_lease && exit 0       # a claude-run session is in progress
    cg_lock >/dev/null
    exit 0
fi

mkdir -p "$CG_STATE_DIR"
date '+%Y-%m-%d %H:%M:%S %z' > "$CG_DISABLE_FLAG"

STILL="$(cg_lock)"
TOTAL="$(cg_lock_files | grep -c . || true)"

printf '\n\033[1;41;97m  CLAUDE CODE DISABLED  \033[0m\n\n'
printf '  flag:      %s\n' "$CG_DISABLE_FLAG"
if [ "${STILL:-0}" -gt 0 ]; then
    printf '  \033[1;31mbinaries:  %s of %s could NOT be made non-executable\033[0m\n' "$STILL" "$TOTAL"
    printf '             Check ownership and the filesystem type.\n'
else
    printf '  binaries:  %s file(s) made non-executable\n' "$TOTAL"
fi
if cg_live_lease; then
    printf '  \033[33mnote:      a claude-run session is live; it keeps running until it exits\033[0m\n'
fi
printf '\n  One deliberate session:  claude-run\n'
printf '  Disarm entirely:         claude-unblock\n\n'

[ "${STILL:-0}" -eq 0 ]
