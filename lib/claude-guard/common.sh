#!/bin/bash
# Shared logic for the Claude Code repository guard.
#
# Installed by `lazy claude.guard`. The @@...@@ markers are filled in at install
# time; do not edit this copy by hand -- re-run `lazy claude.guard` instead.
#
# This file is PURE: it inspects git, paths and permissions but never launches
# Claude Code. That is deliberate, so the allowlist can be unit-tested by
# sourcing it with no risk of starting a session.

# --- Installed layout ------------------------------------------------------
CG_REAL_BIN="@@REAL_BIN@@"
CG_LOCK_DIR="@@LOCK_DIR@@"
CG_GUARD_DIR="@@GUARD_DIR@@"
CG_STATE_DIR="$HOME/.claude"
CG_DISABLE_FLAG="$CG_STATE_DIR/claude-code-disabled"
CG_LEASE_DIR="$CG_STATE_DIR/claude-run-leases"

# --- Allowlist -------------------------------------------------------------
# Matched against the normalized "host/org/repo". "*" only ever stands for one
# path segment, because normalization rejects anything that is not exactly
# host + org + repo.
CG_ALLOWLIST=(
@@ALLOWLIST@@
)

cg_allowlist_print() {
    local p
    for p in ${CG_ALLOWLIST[@]+"${CG_ALLOWLIST[@]}"}; do
        printf '  %s\n' "$p"
    done
}

cg_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Resolve a symlink chain without readlink -f, which BSD/macOS lacks.
cg_resolve() {
    local p="$1" dir target hops=0

    [ -n "$p" ] || return 1
    while [ -L "$p" ]; do
        hops=$((hops + 1))
        [ "$hops" -gt 40 ] && return 1
        dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
        target="$(readlink "$p")" || return 1
        case "$target" in
            /*) p="$target" ;;
            *) p="$dir/$target" ;;
        esac
    done

    [ -e "$p" ] || return 1
    dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
    printf '%s/%s\n' "${dir%/}" "$(basename "$p")"
}

# Every file whose execute bit the kill switch toggles.
#
# The native installer keeps one binary per release in a versions directory and
# repoints a launcher symlink at it, so locking only today's target would be
# undone by the next auto-update. An npm or Homebrew install has no such
# directory; there the resolved binary itself is the only thing to lock.
cg_lock_files() {
    local f

    if [ -n "$CG_LOCK_DIR" ] && [ -d "$CG_LOCK_DIR" ]; then
        for f in "$CG_LOCK_DIR"/*; do
            [ -f "$f" ] && printf '%s\n' "$f"
        done
        return 0
    fi

    f="$(cg_resolve "$CG_REAL_BIN")" || return 1
    [ -f "$f" ] && printf '%s\n' "$f"
}

cg_is_disabled() {
    [ -e "$CG_DISABLE_FLAG" ]
}

# True while a `claude-run` session is live. Leases of dead processes are
# pruned on the way past, so a session killed with SIGKILL cannot wedge the
# kill switch in the off position forever.
cg_live_lease() {
    local f pid found=1

    [ -d "$CG_LEASE_DIR" ] || return 1
    for f in "$CG_LEASE_DIR"/*; do
        [ -f "$f" ] || continue
        pid="$(basename "$f")"
        case "$pid" in
            ''|*[!0-9]*) rm -f "$f" 2>/dev/null; continue ;;
        esac
        if kill -0 "$pid" 2>/dev/null; then
            found=0
        else
            rm -f "$f" 2>/dev/null
        fi
    done

    return $found
}

# Drop the execute bit everywhere. Prints the number of files still executable
# afterwards, so callers can tell a real failure from a clean lock.
cg_lock() {
    local f still=0

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        chmod a-x "$f" 2>/dev/null
        [ -x "$f" ] && still=$((still + 1))
    done <<EOF
$(cg_lock_files)
EOF

    printf '%s' "$still"
    [ "$still" -eq 0 ]
}

cg_unlock() {
    local f rc=0

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        chmod u+x "$f" 2>/dev/null || rc=1
    done <<EOF
$(cg_lock_files)
EOF

    return $rc
}

# --- Remote normalization --------------------------------------------------
# Prints "host/org/repo", lowercased and without a .git suffix. Returns 1 for
# anything that cannot be parsed into exactly that shape, which is what keeps
# lookalikes such as github.com.evil.com or a path with .. out of the allowlist.
cg_normalize_remote() {
    local url="$1" rest host path org repo

    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    [ -n "$url" ] || return 1

    # No whitespace or control characters survive here: the string was trimmed
    # above, so anything left is not a remote URL. Character classes, not
    # $(printf '\n'): command substitution strips the trailing newline, which
    # turns the pattern into *""* and matches everything.
    case "$url" in
        *[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
    esac

    case "$url" in
        ssh://*|git+ssh://*|https://*|http://*|git://*|ftp://*|ftps://*)
            rest="${url#*://}"
            rest="${rest#*@}"
            host="${rest%%/*}"
            [ "$host" = "$rest" ] && return 1
            host="${host%%:*}"
            path="${rest#*/}"
            ;;
        file://*|/*|./*|../*|~*)
            return 1
            ;;
        *:*)
            host="${url%%:*}"
            host="${host#*@}"
            path="${url#*:}"
            case "$path" in /*) return 1 ;; esac
            ;;
        *)
            return 1
            ;;
    esac

    path="${path#/}"
    path="${path%/}"
    [ -n "$host" ] && [ -n "$path" ] || return 1

    case "$path" in *.git) path="${path%.git}" ;; esac
    case "$path" in
        *".."*|*"//"*|*" "*) return 1 ;;
    esac

    org="${path%%/*}"
    repo="${path#*/}"
    [ "$org" != "$path" ] || return 1
    case "$repo" in */*) return 1 ;; esac
    [ -n "$org" ] && [ -n "$repo" ] || return 1

    printf '%s/%s/%s\n' "$(cg_lower "$host")" "$(cg_lower "$org")" "$(cg_lower "$repo")"
}

# Prints the normalized id when the remote is allowed.
cg_is_allowed() {
    local url="$1" norm pat

    norm="$(cg_normalize_remote "$url")" || return 1
    for pat in ${CG_ALLOWLIST[@]+"${CG_ALLOWLIST[@]}"}; do
        # shellcheck disable=SC2254  # the pattern is the point
        case "$norm" in
            $pat) printf '%s\n' "$norm"; return 0 ;;
        esac
    done

    return 1
}

# Prints ONE line either way, so it survives $( ), which is a subshell:
#   rc 0 -> the normalized "host/org/repo"
#   rc>0 -> a human-readable reason (2 non-git, 3 no origin, 4 not allowed,
#           5 git unavailable)
cg_check_cwd() {
    local url norm

    command -v git >/dev/null 2>&1 || {
        printf 'git is not available, so the repository cannot be verified.\n'
        return 5
    }

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        printf 'Not inside a git repository.\n'
        return 2
    }

    url="$(git remote get-url origin 2>/dev/null)" || url=""
    [ -n "$url" ] || {
        printf "This repository has no 'origin' remote (or it could not be read).\n"
        return 3
    }

    norm="$(cg_is_allowed "$url")" || {
        printf 'Repository is not on the allowlist. origin: %s\n' "$url"
        return 4
    }

    printf '%s\n' "$norm"
}
