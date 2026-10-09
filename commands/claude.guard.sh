#!/bin/bash
#
# lazy claude.guard — stop Claude Code starting in a repository that is not
# yours to run it in.
#
# Claude Code can be configured to report the current Git repository name to a
# monitoring backend. On a machine where that is set up, opening Claude Code in
# a personal side project leaks that project's name to the employer's telemetry.
# The usual advice -- "just be careful which directory you are in" -- fails
# exactly once and cannot be taken back.
#
# This installs two layers in front of the real executable:
#
#   1. a repository allowlist: `claude` only starts when the origin remote of
#      the current repository matches, so a non-Git directory, a repository
#      with no origin, and anybody else's repository are all refused;
#   2. a kill switch, armed by default: `claude` refuses everywhere, and the
#      execute bit is removed from the executable so an absolute path cannot
#      get round it either. `claude-run` then opens it for exactly one session.
#      `--no-arm` installs layer 1 on its own.
#
# It does not touch telemetry, OTEL variables, or managed settings. The point
# is to keep Claude Code out of the wrong repository, not out of monitoring.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

TEMPLATE_DIR="${SCRIPT_DIR}/../lib/claude-guard"

GUARD_DIR="${HOME}/.local/bin-guard"
STATE_DIR="${HOME}/.claude"
DISABLE_FLAG="${STATE_DIR}/claude-code-disabled"
LEASE_DIR="${STATE_DIR}/claude-run-leases"

BLOCK_OPEN='# >>> lazy claude.guard >>>'
BLOCK_CLOSE='# <<< lazy claude.guard <<<'

# An earlier hand-rolled version of this guard used its own markers. Left in
# place it would prepend the guard directory to PATH a second time and call a
# claude-reblock this command has just deleted, so it is stripped too.
LEGACY_OPEN='# >>> claude-code repository guard >>>'
LEGACY_CLOSE='# <<< claude-code repository guard <<<'

usage() {
    echo "Usage:"
    echo "  lazy claude.guard [--check] [-y] [--no-arm] [--exact] [--allow <pattern>]..."
    echo "                    [--bin <path>] [--rc <file>] [--uninstall]"
    echo ""
    echo "Installs a repository allowlist in front of Claude Code, derived from the"
    echo "origin remote of the repository you run this in, plus a kill switch that is"
    echo "armed by default."
    echo ""
    echo "Options:"
    echo "      --check            Report what is installed and what would change; change nothing"
    echo "  -y, --yes              Apply without asking for confirmation"
    echo "      --no-arm           Install the allowlist only, leaving the kill switch disarmed"
    echo "      --arm              Arm the kill switch (the default; accepted for clarity)"
    echo "      --exact            Allow only this one repository, not its whole organisation"
    echo "      --allow <pattern>  Extra allowlist entry, e.g. 'github.com/other-org/*' (repeatable)"
    echo "      --bin <path>       Path to the real Claude Code executable (default: detected)"
    echo "      --rc <file>        Shell startup file to wire up (default: detected)"
    echo "      --uninstall        Remove the guard, restore the executable, clean the startup file"
    echo "  -h, --help             Show this help"
    echo ""
    echo "After installing, 'claude' refuses everywhere, because the kill switch is armed"
    echo "by default. Use 'claude-run' for one session; it re-arms the switch when Claude"
    echo "Code exits. With --no-arm only the allowlist applies, so 'claude' still starts"
    echo "inside an allowlisted repository."
}

CHECK_ONLY=0
ASSUME_YES=0
# Armed by default. With the kill switch off, `claude` still starts inside an
# allowlisted repository, which reads as "the guard is not working" to anyone
# who installed this to stop themselves reaching for `claude` at all.
DO_ARM=1
EXACT=0
UNINSTALL=0
OPT_BIN=""
OPT_RC=""
EXTRA_ALLOW=()

need_value() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: Option '$1' needs a value."
        echo ""
        usage
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --arm) DO_ARM=1 ;;
        --no-arm) DO_ARM=0 ;;
        --exact) EXACT=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --allow) need_value "$@"; EXTRA_ALLOW+=("$2"); shift ;;
        --bin) need_value "$@"; OPT_BIN="$2"; shift ;;
        --rc) need_value "$@"; OPT_RC="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1"; echo ""; usage; exit 1 ;;
        *) echo "Error: Unexpected argument -> $1"; echo ""; usage; exit 1 ;;
    esac
    shift
done

PLATFORM="$(platform_id)"
case "$PLATFORM" in
    linux|wsl|macos) ;;
    *)
        echo "Error: 'lazy claude.guard' is not available on $(platform_label "$PLATFORM")."
        echo "       The kill switch depends on a real Unix execute bit, which NTFS does not have."
        exit 1
        ;;
esac

for f in common.sh shim.sh run.sh reblock.sh unblock.sh; do
    if [ ! -f "$TEMPLATE_DIR/$f" ]; then
        echo "Error: Missing guard template -> $TEMPLATE_DIR/$f"
        echo "       The CLI install looks incomplete; run 'lazy update'."
        exit 1
    fi
done

# --- Locate the real executable ----------------------------------------------

# Never the shim: once installed it is first on PATH and answers to `claude`,
# so a plain `command -v claude` would point the guard at itself.
find_real_bin() {
    local dir candidate

    if [ -n "$OPT_BIN" ]; then
        printf '%s' "$OPT_BIN"
        return 0
    fi

    local saved_ifs="$IFS"
    IFS=:
    for dir in $PATH; do
        IFS="$saved_ifs"
        [ -n "$dir" ] || continue
        case "$dir" in "$GUARD_DIR"|"$GUARD_DIR"/) continue ;; esac
        candidate="$dir/claude"
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        IFS=:
    done
    IFS="$saved_ifs"

    for candidate in \
        "$HOME/.local/bin/claude" \
        "/usr/local/bin/claude" \
        "/opt/homebrew/bin/claude"
    do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

REAL_BIN="$(find_real_bin || true)"

if [ "$UNINSTALL" -eq 0 ] && [ -z "$REAL_BIN" ]; then
    echo "Error: No Claude Code executable found."
    echo "       Install Claude Code first, or point at it with --bin <path>."
    exit 1
fi

resolve_path() {
    local p="$1" dir target hops=0
    [ -n "$p" ] || return 1
    while [ -L "$p" ]; do
        hops=$((hops + 1)); [ "$hops" -gt 40 ] && return 1
        dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
        target="$(readlink "$p")" || return 1
        case "$target" in /*) p="$target" ;; *) p="$dir/$target" ;; esac
    done
    [ -e "$p" ] || return 1
    dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
    printf '%s/%s' "${dir%/}" "$(basename "$p")"
}

RESOLVED_BIN=""
[ -n "$REAL_BIN" ] && RESOLVED_BIN="$(resolve_path "$REAL_BIN" || true)"

# The native installer keeps one binary per release here and repoints the
# launcher symlink on every auto-update, so the kill switch has to lock the
# whole directory. A Homebrew or npm install has no such directory and the
# resolved binary is locked on its own.
LOCK_DIR=""
if [ -n "$RESOLVED_BIN" ]; then
    case "$RESOLVED_BIN" in
        "$HOME"/.local/share/claude/versions/*)
            LOCK_DIR="$HOME/.local/share/claude/versions"
            ;;
    esac
fi

# --- Shell startup file ------------------------------------------------------

# Every startup file that has to carry the block.
#
# One file is not enough. Debian/Ubuntu's ~/.profile sources ~/.bashrc first
# and prepends ~/.local/bin afterwards, so a block written only to ~/.bashrc
# runs too early and the real launcher ends up ahead of the guard. Whichever
# file runs last has to put the guard back in front, so the block goes in all
# of them; it is idempotent by design.
find_rc_files() {
    local shell_name f

    if [ -n "$OPT_RC" ]; then
        printf '%s\n' "$OPT_RC"
        return 0
    fi

    shell_name="$(basename "${SHELL:-/bin/bash}")"
    if [ "$shell_name" = "zsh" ]; then
        # zsh reads .zprofile before .zshrc, so .zshrc is already the last word.
        printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
        return 0
    fi

    printf '%s\n' "$HOME/.bashrc"

    local found=0
    for f in "$HOME/.bash_profile" "$HOME/.profile"; do
        if [ -f "$f" ]; then
            printf '%s\n' "$f"
            found=1
        fi
    done

    # With no login file at all, a bash login shell reads neither .bash_profile
    # nor .bashrc, so the guard would simply not apply there. Name ~/.profile so
    # it gets created.
    [ "$found" -eq 0 ] && printf '%s\n' "$HOME/.profile"
    return 0
}

RC_FILES=()
while IFS= read -r f; do
    [ -n "$f" ] && RC_FILES+=("$f")
done <<EOF
$(find_rc_files)
EOF
RC_FILE="${RC_FILES[0]}"

# --- Allowlist ---------------------------------------------------------------

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Same parser the installed guard uses; kept here so the plan can be shown and
# confirmed before anything is written.
normalize_remote() {
    local url="$1" rest host path org repo

    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    [ -n "$url" ] || return 1

    case "$url" in
        ssh://*|git+ssh://*|https://*|http://*|git://*)
            rest="${url#*://}"; rest="${rest#*@}"
            host="${rest%%/*}"; [ "$host" = "$rest" ] && return 1
            host="${host%%:*}"; path="${rest#*/}"
            ;;
        file://*|/*|./*|../*|~*) return 1 ;;
        *:*)
            host="${url%%:*}"; host="${host#*@}"; path="${url#*:}"
            case "$path" in /*) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac

    path="${path#/}"; path="${path%/}"
    [ -n "$host" ] && [ -n "$path" ] || return 1
    case "$path" in *.git) path="${path%.git}" ;; esac
    case "$path" in *".."*|*"//"*|*" "*) return 1 ;; esac

    org="${path%%/*}"; repo="${path#*/}"
    [ "$org" != "$path" ] || return 1
    case "$repo" in */*) return 1 ;; esac
    [ -n "$org" ] && [ -n "$repo" ] || return 1

    printf '%s/%s/%s' "$(lower "$host")" "$(lower "$org")" "$(lower "$repo")"
}

# A per-account SSH alias ("Host github.com-work" -> "HostName github.com")
# makes the remote read github.com-work, while the same repository cloned on
# another machine reads github.com. Both spellings name the same organisation,
# so both belong on the allowlist.
ssh_alias_hostname() {
    local alias_name="$1" line in_block=0 host_field

    [ -f "$HOME/.ssh/config" ] || return 1
    while IFS= read -r line; do
        case "$(lower "$line")" in
            host\ *|host=*)
                in_block=0
                host_field="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[Hh]ost[[:space:]=]+//')"
                for h in $host_field; do
                    [ "$(lower "$h")" = "$(lower "$alias_name")" ] && in_block=1
                done
                ;;
            *hostname\ *|*hostname=*)
                if [ "$in_block" -eq 1 ]; then
                    printf '%s' "$(lower "$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[Hh]ost[Nn]ame[[:space:]=]+//' | tr -d '[:space:]')")"
                    return 0
                fi
                ;;
        esac
    done < "$HOME/.ssh/config"

    return 1
}

ORIGIN_URL=""
ORIGIN_NORM=""
ORIGIN_NOTE=""
ALLOW=()

derive_allowlist() {
    local host org repo base
    local pattern

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        ORIGIN_NOTE="not inside a Git repository"
        return 1
    fi

    ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" || ORIGIN_URL=""
    if [ -z "$ORIGIN_URL" ]; then
        ORIGIN_NOTE="this repository has no 'origin' remote"
        return 1
    fi

    ORIGIN_NORM="$(normalize_remote "$ORIGIN_URL")" || {
        ORIGIN_NOTE="the origin remote could not be parsed into host/org/repo"
        return 1
    }

    host="${ORIGIN_NORM%%/*}"
    org="${ORIGIN_NORM#*/}"; org="${org%%/*}"
    repo="${ORIGIN_NORM##*/}"

    if [ "$EXACT" -eq 1 ]; then
        ALLOW+=("$host/$org/$repo")
    else
        ALLOW+=("$host/$org/*")
    fi

    # Add the alias's real hostname so the same organisation is recognised when
    # cloned without the alias.
    base="$(ssh_alias_hostname "$host" || true)"
    if [ -n "$base" ] && [ "$base" != "$host" ]; then
        if [ "$EXACT" -eq 1 ]; then
            ALLOW+=("$base/$org/$repo")
        else
            ALLOW+=("$base/$org/*")
        fi
        ORIGIN_NOTE="'$host' is an SSH alias for '$base' in ~/.ssh/config; both are allowed"
    fi

    for pattern in ${EXTRA_ALLOW[@]+"${EXTRA_ALLOW[@]}"}; do
        ALLOW+=("$(lower "$pattern")")
    done

    return 0
}

if [ "$UNINSTALL" -eq 0 ]; then
    if ! derive_allowlist; then
        if [ "${#EXTRA_ALLOW[@]}" -eq 0 ]; then
            echo "Error: Cannot work out which repositories to allow -- $ORIGIN_NOTE."
            echo ""
            echo "Run this inside the company repository you want to allow, so its origin"
            echo "remote can be read, or state the patterns yourself:"
            echo "  lazy claude.guard --allow 'github.com/your-org/*'"
            exit 1
        fi
        for pattern in "${EXTRA_ALLOW[@]}"; do
            ALLOW+=("$(lower "$pattern")")
        done
    fi
fi

# --- Current state -----------------------------------------------------------

installed_files() {
    printf '%s\n' \
        "$GUARD_DIR/claude" \
        "$GUARD_DIR/claude-run" \
        "$GUARD_DIR/claude-reblock" \
        "$GUARD_DIR/claude-unblock" \
        "$GUARD_DIR/claude-guard-common.sh"
}

# An earlier hand-rolled version of this guard put its scripts straight into
# ~/.local/bin. They are shadowed by the guard directory rather than used, so
# they are only confusing; offer to clear them out.
legacy_files() {
    printf '%s\n' \
        "$HOME/.local/bin/claude-guard" \
        "$HOME/.local/bin/claude-guard-allowlist.sh" \
        "$HOME/.local/bin/claude-run" \
        "$HOME/.local/bin/claude-reblock" \
        "$HOME/.local/bin/claude-unblock"
}

rc_has_block() {
    local f
    for f in "${RC_FILES[@]}"; do
        [ -f "$f" ] && grep -qF "$BLOCK_OPEN" "$f" && return 0
    done
    return 1
}

# True only when every target file carries it; a block in .bashrc but not in
# .profile is exactly the half-wired state this command exists to avoid.
rc_fully_wired() {
    local f
    for f in "${RC_FILES[@]}"; do
        [ -f "$f" ] && grep -qF "$BLOCK_OPEN" "$f" || return 1
    done
    return 0
}

rc_has_legacy_block() {
    local f
    for f in "${RC_FILES[@]}"; do
        [ -f "$f" ] && grep -qF "$LEGACY_OPEN" "$f" && return 0
    done
    return 1
}

count_executable() {
    local n=0 f
    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        for f in "$LOCK_DIR"/*; do
            [ -f "$f" ] && [ -x "$f" ] && n=$((n + 1))
        done
    elif [ -n "$RESOLVED_BIN" ] && [ -x "$RESOLVED_BIN" ]; then
        n=1
    fi
    printf '%s' "$n"
}

INSTALLED=0
installed_files | while IFS= read -r f; do [ -e "$f" ] || exit 1; done && INSTALLED=1

LEGACY_PRESENT=()
while IFS= read -r f; do
    [ -e "$f" ] && LEGACY_PRESENT+=("$f")
done <<EOF
$(legacy_files)
EOF

# On WSL a Windows-side Claude Code install is reachable as claude.exe and the
# Unix execute bit means nothing on /mnt/c, so the only thing that can be done
# from this side is to shadow the name.
WIN_EXE=""
if [ "$PLATFORM" = "wsl" ]; then
    WIN_EXE="$(command -v claude.exe 2>/dev/null || true)"
    case "$WIN_EXE" in "$GUARD_DIR"/*) WIN_EXE="" ;; esac
fi

# --- Report ------------------------------------------------------------------

echo "Platform:    $(platform_label "$PLATFORM")"
if [ "$UNINSTALL" -eq 0 ]; then
    echo "Executable:  ${REAL_BIN:-not found}"
    [ -n "$RESOLVED_BIN" ] && [ "$RESOLVED_BIN" != "$REAL_BIN" ] && echo "             -> $RESOLVED_BIN"
    if [ -n "$LOCK_DIR" ]; then
        echo "Locks:       every release in $LOCK_DIR"
    else
        echo "Locks:       ${RESOLVED_BIN:-n/a}"
    fi
fi
echo "Guard dir:   $GUARD_DIR"
printf 'Startup:    '
for f in "${RC_FILES[@]}"; do
    printf ' %s%s' "$f" "$( [ -f "$f" ] && grep -qF "$BLOCK_OPEN" "$f" && echo ' (wired)' )"
done
printf '\n' 

if [ "$UNINSTALL" -eq 0 ]; then
    echo "Allowlist:"
    for pattern in "${ALLOW[@]}"; do
        echo "  $pattern"
    done
    [ -n "$ORIGIN_URL" ] && echo "             from origin: $ORIGIN_URL"
    [ -n "$ORIGIN_NOTE" ] && echo "             note: $ORIGIN_NOTE"
fi

if [ -e "$DISABLE_FLAG" ]; then
    echo "Kill switch: ARMED since $(head -1 "$DISABLE_FLAG" 2>/dev/null)"
else
    echo "Kill switch: off"
fi
echo "Executable now: $(count_executable) file(s) carry the execute bit"

if [ "${#LEGACY_PRESENT[@]}" -gt 0 ]; then
    echo ""
    echo "Older hand-installed copies found (shadowed, not used):"
    for f in "${LEGACY_PRESENT[@]}"; do echo "  $f"; done
fi

if [ -n "$WIN_EXE" ]; then
    echo ""
    echo "Windows-side Claude Code is reachable from WSL:"
    echo "  $WIN_EXE"
    echo "  It will be shadowed as 'claude.exe' here, but running it from PowerShell"
    echo "  or cmd stays outside this guard entirely."
fi

echo ""

# --- Plan --------------------------------------------------------------------

PLAN=()

if [ "$UNINSTALL" -eq 1 ]; then
    [ "$(count_executable)" -eq 0 ] && PLAN+=("restore the execute bit on the Claude Code executable")
    [ -e "$DISABLE_FLAG" ] && PLAN+=("clear the kill switch flag")
    while IFS= read -r f; do
        [ -e "$f" ] && PLAN+=("remove $f")
    done <<EOF
$(installed_files)
EOF
    [ -e "$GUARD_DIR/claude.exe" ] && PLAN+=("remove $GUARD_DIR/claude.exe")
    [ -d "$LEASE_DIR" ] && PLAN+=("remove $LEASE_DIR")
    rc_has_block && PLAN+=("remove the guard block from: ${RC_FILES[*]}")
    rc_has_legacy_block && PLAN+=("remove the superseded guard block too")
else
    PLAN+=("write the guard scripts into $GUARD_DIR")
    if rc_has_block; then
        PLAN+=("refresh the guard block in: ${RC_FILES[*]}")
    else
        PLAN+=("add a guard block (PATH + self-heal) to: ${RC_FILES[*]}")
    fi
    [ -n "$WIN_EXE" ] && PLAN+=("shadow claude.exe inside $GUARD_DIR")
    rc_has_legacy_block && PLAN+=("remove the superseded guard block from the startup files")
    for f in ${LEGACY_PRESENT[@]+"${LEGACY_PRESENT[@]}"}; do
        PLAN+=("remove the superseded $f")
    done
    if [ "$DO_ARM" -eq 1 ]; then
        PLAN+=("arm the kill switch: 'claude' will refuse in EVERY directory")
        PLAN+=("  (use 'claude-run' for one session, or re-run with --no-arm)")
    elif [ -e "$DISABLE_FLAG" ]; then
        PLAN+=("disarm the kill switch: 'claude' will start inside an allowlisted repository")
    else
        PLAN+=("leave the kill switch off: 'claude' starts inside an allowlisted repository")
    fi
fi

echo "Will:"
for line in "${PLAN[@]}"; do
    printf '  %s\n' "$line"
done
echo ""

if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ "$UNINSTALL" -eq 0 ] && [ "$INSTALLED" -eq 1 ] && rc_fully_wired \
        && ! rc_has_legacy_block && [ "${#LEGACY_PRESENT[@]}" -eq 0 ]; then
        echo "The guard is installed. Re-run without --check to refresh it."
        exit 0
    fi
    echo "Run without --check to apply."
    exit 1
fi

has_tty() { { : < /dev/tty; } 2>/dev/null; }

if [ "$ASSUME_YES" -ne 1 ]; then
    if ! has_tty; then
        echo "Error: Confirmation needs an interactive terminal. Re-run with -y to apply."
        exit 1
    fi
    printf 'Apply? [y/N] '
    read -r answer < /dev/tty || answer=""
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled. Nothing was changed."; exit 1 ;;
    esac
    echo ""
fi

# --- Startup file block ------------------------------------------------------

# Removes one marker-delimited block from one file, in place.
strip_block() {
    local file="$1" openmark="$2" closemark="$3" tmp

    [ -f "$file" ] || return 0
    grep -qF "$openmark" "$file" || return 0

    tmp="$(mktemp "${TMPDIR:-/tmp}/lazy-claude-guard.XXXXXX")" || return 1
    # openmark/closemark, not open/close: gawk refuses a variable named after
    # one of its builtins.
    awk -v openmark="$openmark" -v closemark="$closemark" '
        index($0, openmark) { skip = 1 }
        !skip { print }
        index($0, closemark) { skip = 0 }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

strip_rc_block() {
    local f
    for f in "${RC_FILES[@]}"; do
        strip_block "$f" "$BLOCK_OPEN" "$BLOCK_CLOSE" || return 1
        strip_block "$f" "$LEGACY_OPEN" "$LEGACY_CLOSE" || return 1
    done
}

write_rc_block() {
    local file dir_literal="$GUARD_DIR"
    case "$dir_literal" in
        "$HOME"/*) dir_literal="\$HOME/${dir_literal#"$HOME"/}" ;;
    esac

    for file in "${RC_FILES[@]}"; do
        mkdir -p "$(dirname "$file")"
        {
            printf '\n%s\n' "$BLOCK_OPEN"
            printf '# Put the guard ahead of the real Claude Code launcher. PATH rather than\n'
            printf '# an alias or a function, so `command claude`, `\\claude` and\n'
            printf '# non-interactive child shells go through it too.\n'
            printf '#\n'
            printf '# Prepend unless it is ALREADY FIRST, rather than only when it is absent.\n'
            printf "# Debian/Ubuntu's ~/.profile sources ~/.bashrc and prepends ~/.local/bin\n"
            printf '# afterwards, which puts the real launcher ahead of the guard. An\n'
            printf '# "add it if missing" test would see the guard somewhere on PATH, do\n'
            printf '# nothing, and leave the guard bypassed in every shell from then on.\n'
            printf '# This form is plain POSIX: no word splitting, no bashisms, so it is\n'
            printf '# safe in .profile under dash as well as in bash and zsh.\n'
            printf 'case "$PATH" in\n'
            printf '    "%s:"*) ;;\n' "$dir_literal"
            printf '    *) PATH="%s:$PATH"; export PATH ;;\n' "$dir_literal"
            printf 'esac\n'
            printf 'unset -f claude 2>/dev/null\n'
            printf '# Self-heal: Claude Code is a TUI and runs in the foreground, and bash\n'
            printf '# defers traps while a foreground child runs, so a claude-run session\n'
            printf '# killed with SIGKILL never reaches its cleanup and would leave the kill\n'
            printf '# switch silently off. Re-assert it here; skipped while a session is live.\n'
            printf 'if [ -e "$HOME/.claude/claude-code-disabled" ] && [ -x "%s/claude-reblock" ]; then\n' "$dir_literal"
            printf '    "%s/claude-reblock" -q 2>/dev/null\n' "$dir_literal"
            printf 'fi\n'
            printf '%s\n' "$BLOCK_CLOSE"
        } >> "$file"
    done
}

# --- Uninstall ---------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
    echo "Applying:"

    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        for f in "$LOCK_DIR"/*; do [ -f "$f" ] && chmod u+x "$f" 2>/dev/null; done
        echo "  restored the execute bit in $LOCK_DIR"
    elif [ -n "$RESOLVED_BIN" ]; then
        chmod u+x "$RESOLVED_BIN" 2>/dev/null && echo "  restored the execute bit on $RESOLVED_BIN"
    fi

    rm -f "$DISABLE_FLAG" && echo "  cleared the kill switch flag"
    rm -rf "$LEASE_DIR"

    while IFS= read -r f; do
        [ -e "$f" ] && rm -f "$f" && echo "  removed $f"
    done <<EOF
$(installed_files)
EOF
    [ -e "$GUARD_DIR/claude.exe" ] && rm -f "$GUARD_DIR/claude.exe" && echo "  removed $GUARD_DIR/claude.exe"
    rmdir "$GUARD_DIR" 2>/dev/null && echo "  removed $GUARD_DIR"

    if rc_has_block || rc_has_legacy_block; then
        strip_rc_block && echo "  removed the guard block from: ${RC_FILES[*]}"
    fi

    echo ""
    echo "Done. Open a new terminal: 'claude' goes straight to $REAL_BIN again."
    exit 0
fi

# --- Install -----------------------------------------------------------------

render() {
    local src="$1" dest="$2" line pattern tmp

    tmp="$(mktemp "${TMPDIR:-/tmp}/lazy-claude-guard.XXXXXX")" || return 1
    {
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                *@@ALLOWLIST@@*)
                    for pattern in "${ALLOW[@]}"; do
                        printf '    "%s"\n' "$pattern"
                    done
                    continue
                    ;;
            esac
            line="${line//@@REAL_BIN@@/$REAL_BIN}"
            line="${line//@@LOCK_DIR@@/$LOCK_DIR}"
            line="${line//@@GUARD_DIR@@/$GUARD_DIR}"
            printf '%s\n' "$line"
        done < "$src"
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    cat "$tmp" > "$dest" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

echo "Applying:"

mkdir -p "$GUARD_DIR" "$STATE_DIR" || exit 1

render "$TEMPLATE_DIR/common.sh"  "$GUARD_DIR/claude-guard-common.sh" || exit 1
chmod 0644 "$GUARD_DIR/claude-guard-common.sh"
render "$TEMPLATE_DIR/shim.sh"    "$GUARD_DIR/claude"          || exit 1
render "$TEMPLATE_DIR/run.sh"     "$GUARD_DIR/claude-run"      || exit 1
render "$TEMPLATE_DIR/reblock.sh" "$GUARD_DIR/claude-reblock"  || exit 1
render "$TEMPLATE_DIR/unblock.sh" "$GUARD_DIR/claude-unblock"  || exit 1
chmod 0755 "$GUARD_DIR/claude" "$GUARD_DIR/claude-run" \
           "$GUARD_DIR/claude-reblock" "$GUARD_DIR/claude-unblock"
echo "  wrote the guard scripts into $GUARD_DIR"

if [ -n "$WIN_EXE" ]; then
    ln -sf claude "$GUARD_DIR/claude.exe"
    echo "  shadowed claude.exe (Windows build stays reachable from PowerShell)"
fi

for f in ${LEGACY_PRESENT[@]+"${LEGACY_PRESENT[@]}"}; do
    rm -f "$f" && echo "  removed the superseded $f"
done

strip_rc_block || exit 1
write_rc_block || exit 1
echo "  wired: ${RC_FILES[*]}"

if [ "$DO_ARM" -eq 1 ]; then
    "$GUARD_DIR/claude-reblock" >/dev/null 2>&1 || true
    echo "  armed the kill switch"
elif [ -e "$DISABLE_FLAG" ]; then
    # --no-arm on a machine where it is already armed has to actually disarm,
    # or the flag would silently outlive the request.
    "$GUARD_DIR/claude-unblock" >/dev/null 2>&1 || true
    echo "  disarmed the kill switch (--no-arm)"
fi

# --- Verify ------------------------------------------------------------------

echo ""
FAIL=0

for f in $(installed_files); do
    [ -e "$f" ] || { echo "Missing after install: $f"; FAIL=1; }
done
bash -n "$GUARD_DIR/claude" 2>/dev/null || { echo "Generated shim has a syntax error."; FAIL=1; }
bash -n "$GUARD_DIR/claude-guard-common.sh" 2>/dev/null || { echo "Generated library has a syntax error."; FAIL=1; }

# Does `claude` actually reach the guard? Resolution only -- `command -v` in a
# login+interactive shell, which is the combination that reads every startup
# file. Nothing is executed. This check exists because a guard that is on PATH
# but not FIRST looks perfectly installed while being completely bypassed.
RESOLVED_CLAUDE="$(bash -lic 'command -v claude' 2>/dev/null | tail -1)"
if [ -n "$RESOLVED_CLAUDE" ]; then
    if [ "$RESOLVED_CLAUDE" = "$GUARD_DIR/claude" ]; then
        echo "Verified: in a new login shell, 'claude' resolves to the guard."
    else
        echo "Verification FAILED: in a login shell 'claude' resolves to"
        echo "  $RESOLVED_CLAUDE"
        echo "  instead of $GUARD_DIR/claude -- something later on PATH shadows the guard."
        echo "  Startup files wired: ${RC_FILES[*]}"
        FAIL=1
    fi
else
    echo "Note: could not resolve 'claude' in a test login shell; check manually with"
    echo "  bash -lic 'command -v claude'"
fi

# The allowlist has to accept the repository it was derived from. Checked by
# sourcing the generated library, which never launches Claude Code.
if [ -n "$ORIGIN_URL" ]; then
    if ( . "$GUARD_DIR/claude-guard-common.sh" && cg_is_allowed "$ORIGIN_URL" >/dev/null ); then
        echo "Verified: this repository is allowed by the generated allowlist."
    else
        echo "Verification failed: the generated allowlist rejects $ORIGIN_URL"
        FAIL=1
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "Install finished with problems; see above."
    exit 1
fi

echo ""
echo "Done. Open a new terminal."
echo ""
if [ -e "$DISABLE_FLAG" ]; then
    echo "  The kill switch is ARMED: 'claude' refuses in every directory."
    echo ""
    echo "  claude-run      how you start a session, in an allowlisted repository"
    echo "  claude          refuses, and says what to run instead"
    echo "  claude-unblock  disarm, so 'claude' works in allowlisted repositories"
    echo "  claude-reblock  arm it again"
else
    echo "  The kill switch is OFF: 'claude' still starts inside an allowlisted"
    echo "  repository. Run 'claude-reblock' to make it refuse everywhere."
    echo ""
    echo "  claude          starts only inside an allowlisted repository"
    echo "  claude-run      one session with the kill switch left as it is"
    echo "  claude-reblock  arm the kill switch"
    echo "  claude-unblock  disarm it"
fi
echo ""
echo "Undo everything with: lazy claude.guard --uninstall"
