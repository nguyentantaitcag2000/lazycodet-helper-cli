#!/bin/bash
# Installed by `lazy claude.guard` as <guard-dir>/claude.
#
# Single entry point for the `claude` command: the guard directory is first on
# PATH, so `claude`, `command claude`, `\claude` and non-interactive child
# shells all land here rather than on the real launcher.
#
# Checks, in order:
#   1. kill switch  -> hard stop (use `claude-run` for one deliberate session)
#   2. git repo + origin + allowlist
#   3. exec the real Claude Code executable
#
# Do not edit this copy by hand; re-run `lazy claude.guard`.

set -u

GUARD_LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-guard-common.sh"

die() {
    printf '\n\033[1;31m  CLAUDE CODE BLOCKED \033[0m  %s\n' "$1" >&2
    shift
    while [ "$#" -gt 0 ]; do
        printf '  %s\n' "$1" >&2
        shift
    done
    printf '\n  cwd: %s\n' "$PWD" >&2
    if [ -r "$GUARD_LIB" ]; then
        printf '  allowlist:\n' >&2
        # shellcheck disable=SC1090
        ( . "$GUARD_LIB" && cg_allowlist_print ) >&2
    fi
    printf '\n' >&2
    exit 77
}

[ -r "$GUARD_LIB" ] || die "Guard library missing." "Expected: $GUARD_LIB" \
    "Re-install it with: lazy claude.guard"
# shellcheck disable=SC1090
. "$GUARD_LIB" || die "Guard library failed to load." "File: $GUARD_LIB"

# --- 1. kill switch --------------------------------------------------------
if cg_is_disabled; then
    printf '\n\033[1;41;97m  CLAUDE CODE DISABLED  \033[0m\n\n' >&2
    printf '  The kill switch is armed; no repository can start Claude Code.\n' >&2
    [ -s "$CG_DISABLE_FLAG" ] && printf '  Armed at: %s\n' "$(head -1 "$CG_DISABLE_FLAG")" >&2
    printf '\n  One deliberate session (kill switch stays armed):  claude-run\n' >&2
    printf '  Disarm it entirely:                                claude-unblock\n' >&2
    printf '\n' >&2
    exit 78
fi

# --- 2. integrity ----------------------------------------------------------
[ -x "$CG_REAL_BIN" ] || die \
    "The Claude Code executable is not executable." \
    "Path: $CG_REAL_BIN" \
    "If the kill switch was just armed, use: claude-run  (or claude-unblock)"

if [ "$(cg_resolve "$CG_REAL_BIN")" = "$(cg_resolve "${BASH_SOURCE[0]}")" ]; then
    die "Misconfiguration: the real binary resolves back to this script." \
        "Refusing to run, to avoid infinite recursion."
fi

# --- 3. repository allowlist -----------------------------------------------
CHECK_OUT="$(cg_check_cwd)"
CHECK_RC=$?
[ "$CHECK_RC" -eq 0 ] || die "$CHECK_OUT"

if [ "${CLAUDE_GUARD_VERBOSE:-0}" = "1" ]; then
    printf '\033[2m[claude] allowed: %s\033[0m\n' "$CHECK_OUT" >&2
fi

exec "$CG_REAL_BIN" "$@"
