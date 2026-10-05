#!/bin/bash
# Installed by `lazy claude.guard` as <guard-dir>/claude-run.
#
# Starts ONE deliberate Claude Code session while the kill switch stays armed.
#
# `claude-unblock` disarms the kill switch globally and leaves it disarmed
# until somebody remembers to re-arm it, which in practice means the protection
# disappears after its first use. This instead unlocks the executable for the
# lifetime of one session and locks it again on exit, so the guard re-arms
# itself.
#
# The repository allowlist still applies: this is not a way into a repository
# that is not on it.
#
# Do not edit this copy by hand; re-run `lazy claude.guard`.

set -u

GUARD_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-guard-common.sh"

die() {
    printf '\n\033[1;31m  CLAUDE CODE BLOCKED \033[0m  %s\n' "$1" >&2
    printf '\n  cwd: %s\n' "$PWD" >&2
    if [ -r "$GUARD_LIB" ]; then
        printf '  allowlist:\n' >&2
        # shellcheck disable=SC1090
        ( . "$GUARD_LIB" && cg_allowlist_print ) >&2
    fi
    printf '\n' >&2
    exit 77
}

[ -r "$GUARD_LIB" ] || die "Guard library missing: $GUARD_LIB"
# shellcheck disable=SC1090
. "$GUARD_LIB" || die "Guard library failed to load: $GUARD_LIB"

# Enforced whether or not the kill switch is armed.
CHECK_OUT="$(cg_check_cwd)"
CHECK_RC=$?
[ "$CHECK_RC" -eq 0 ] || die "$CHECK_OUT"

cg_resolve "$CG_REAL_BIN" >/dev/null 2>&1 || die "Claude Code executable not found: $CG_REAL_BIN"

LEASE="$CG_LEASE_DIR/$$"

# Runs at most once. The EXIT trap fires after a signal trap, so without this
# guard the message was printed twice on Ctrl+C.
RELOCKED=0
relock() {
    local still

    [ "$RELOCKED" = "1" ] && return 0
    RELOCKED=1
    rm -f "$LEASE" 2>/dev/null
    cg_is_disabled || return 0          # kill switch was off; leave it alone

    still="$(cg_lock)"
    if [ "${still:-0}" -gt 0 ]; then
        # The case that actually deserves attention.
        printf '\n\033[1;31m  WARNING  \033[0m the kill switch did not re-arm (%s file(s) still executable).\n' "$still" >&2
        printf '  Run: claude-reblock\n\n' >&2
    else
        printf '\033[2m[claude-run] kill switch re-armed\033[0m\n' >&2
    fi
}

if cg_is_disabled; then
    mkdir -p "$CG_LEASE_DIR" && : > "$LEASE"
    # No explicit exit in the signal handlers: bash defers a trap while a
    # foreground child runs, so afterwards the script falls through to
    # `exit $?` and Claude Code's own status is preserved. Forcing exit 130
    # here used to clobber it whenever Ctrl+C was pressed mid-session.
    trap relock EXIT INT TERM HUP
    cg_unlock || die "Could not unlock the Claude Code executable."
    printf '\033[2m[claude-run] %s | kill switch opened for this session, re-arms on exit\033[0m\n' \
        "$CHECK_OUT" >&2
else
    printf '\033[2m[claude-run] %s | kill switch is off\033[0m\n' "$CHECK_OUT" >&2
fi

# A CHILD, not exec: the trap has to regain control to re-arm the kill switch.
"$CG_REAL_BIN" "$@"
exit $?
