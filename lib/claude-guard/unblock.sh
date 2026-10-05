#!/bin/bash
# Installed by `lazy claude.guard` as <guard-dir>/claude-unblock.
#
# Disarms the kill switch entirely: the executable becomes executable again and
# stays that way until `claude-reblock`. The repository allowlist still applies,
# so Claude Code still refuses to start outside the allowed repositories.
#
# For ordinary use prefer `claude-run`, which opens the kill switch for a single
# session and re-arms it on exit.
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

case "${1:-}" in
    "") ;;
    -h|--help) echo "Usage: claude-unblock"; exit 0 ;;
    *) echo "Error: unknown option -> $1" >&2; exit 1 ;;
esac

rm -f "$CG_DISABLE_FLAG"

N=0
FAILED=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if chmod u+x "$f" 2>/dev/null; then
        N=$((N + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done <<EOF
$(cg_lock_files)
EOF

printf '\n\033[1;42;97m  CLAUDE CODE RE-ENABLED  \033[0m\n\n'
printf '  binaries:  %s file(s) made executable again\n' "$N"
[ "$FAILED" -gt 0 ] && printf '  \033[1;31mfailed:    %s file(s) could not be changed\033[0m\n' "$FAILED"
printf '  note:      the repository allowlist is still active, so Claude Code\n'
printf '             still only starts in an allowlisted repository.\n'
printf '\n  Re-arm:  claude-reblock\n\n'

[ "$FAILED" -eq 0 ]
