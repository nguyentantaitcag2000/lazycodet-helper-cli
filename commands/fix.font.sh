#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

usage() {
    echo "Usage:"
    echo "  lazy fix.font [--check] [--dry-run] [-y] [--no-registry]"
    echo ""
    echo "Fixes garbled Vietnamese / accented text on Windows (Git Bash): shell locale,"
    echo "console code page, vim, readline, mintty, git and the Windows console."
    echo ""
    echo "Options:"
    echo "      --check          Report what is wrong and exit without changing anything"
    echo "      --dry-run        Show every change that would be made, without applying it"
    echo "  -y, --yes            Skip the confirmation prompt"
    echo "      --no-registry    Skip the HKCU\\Console and PowerShell profile fixes"
    echo "  -h, --help           Show this help"
}

CHECK_ONLY=0
DRY_RUN=0
ASSUME_YES=0
DO_REGISTRY=1

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --no-registry) DO_REGISTRY=0 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1"; echo ""; usage; exit 1 ;;
        *) echo "Error: fix.font takes no arguments -> $1"; echo ""; usage; exit 1 ;;
    esac
    shift
done

if ! is_git_bash; then
    echo "Info: Linux/WSL already uses UTF-8 by default. Nothing to fix."
    exit 0
fi

BASHRC="${HOME}/.bashrc"
VIMRC="${HOME}/.vimrc"
INPUTRC="${HOME}/.inputrc"
MINTTYRC="${HOME}/.minttyrc"

MARKER="# lazy-cli UTF-8"
VIM_MARKER='" lazy-cli UTF-8'

# key=value pairs written with `git config --global`
GIT_SETTINGS=(
    "core.quotepath=false"
    "i18n.commitencoding=utf-8"
    "i18n.logoutputencoding=utf-8"
    "gui.encoding=utf-8"
)

# ---------------------------------------------------------------- helpers ---

# `locale -a` prints the short form (en_US.utf8) but the canonical name is what
# belongs in .bashrc; both are accepted by the MSYS runtime.
pick_locale() {
    if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
        echo "en_US.UTF-8"
        return 0
    fi

    if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        echo "C.UTF-8"
        return 0
    fi

    echo "en_US.UTF-8"
}

current_codepage() {
    chcp.com 2>/dev/null | tr -d '\r' | sed -n 's/.*: *//p' | head -n 1
}

# Fonts are registered under their full face name, e.g. "Cascadia Mono Regular
# (TrueType)", so allow a style word between the family name and the type.
font_installed() {
    local name="$1"
    local hive

    for hive in HKLM HKCU; do
        if reg.exe query "${hive}\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" 2>/dev/null |
            tr -d '\r' |
            grep -qiE "^[[:space:]]*${name}([[:space:]]+Regular)?[[:space:]]*\("; then
            return 0
        fi
    done

    return 1
}

# Consolas ships with every Windows and covers the full Vietnamese range.
pick_console_font() {
    if font_installed "Cascadia Mono"; then
        echo "Cascadia Mono"
        return 0
    fi

    echo "Consolas"
}

# Files that already had content before this run. Recorded up front so a file
# the command creates itself is never "backed up" to a copy of its own output.
PREEXISTING_FILES=""

snapshot_existing() {
    local file

    for file in "$@"; do
        if [ -s "$file" ]; then
            PREEXISTING_FILES="${PREEXISTING_FILES}:${file}:"
        fi
    done
}

backup_once() {
    local file="$1"

    case "$PREEXISTING_FILES" in
        *":${file}:"*) ;;
        *) return 0 ;;
    esac

    [ -f "${file}.lazy.bak" ] && return 0

    cp "$file" "${file}.lazy.bak" 2>/dev/null || return 0
    echo "  Backup: ${file}.lazy.bak"
}

has_marker() {
    grep -qF "$2" "$1" 2>/dev/null
}

# Marker-guarded append, same idempotency trick the installer uses for PATH.
append_block() {
    local file="$1"
    local marker="$2"
    local body="$3"

    if has_marker "$file" "$marker"; then
        return 1
    fi

    backup_once "$file"
    touch "$file"

    {
        echo ""
        echo "$marker"
        printf '%s\n' "$body"
    } >> "$file"
}

# ~/.minttyrc is Key=Value, so replace the line instead of appending a block.
set_ini_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp

    touch "$file"

    if grep -qxF "${key}=${value}" "$file" 2>/dev/null; then
        return 1
    fi

    backup_once "$file"
    tmp="${file}.lazy.tmp"

    awk -v k="$key" -v v="$value" '
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

ini_key_present() {
    grep -qE "^$2=" "$1" 2>/dev/null
}

# Indent every line of a multi-line body, not just the first.
indent() {
    printf '%s\n' "$1" | sed 's/^/    /'
}

# $PROFILE is authoritative: Documents is often redirected to OneDrive.
powershell_profile() {
    local out

    command -v powershell.exe >/dev/null 2>&1 || return 1
    command -v cygpath >/dev/null 2>&1 || return 1

    out=$(powershell.exe -NoProfile -Command '$PROFILE.CurrentUserAllHosts' 2>/dev/null | tr -d '\r\n')
    [ -n "$out" ] || return 1

    cygpath -u "$out" 2>/dev/null
}

# --------------------------------------------------------------- contents ---

UTF8_LOCALE="$(pick_locale)"
CONSOLE_FONT="$(pick_console_font)"

BASHRC_BODY=$(printf '%s\n' \
    "export LANG=\"\${LANG:-${UTF8_LOCALE}}\"" \
    "export LC_ALL=\"\${LC_ALL:-${UTF8_LOCALE}}\"" \
    "export LC_CTYPE=\"\${LC_CTYPE:-${UTF8_LOCALE}}\"" \
    'case "$-" in' \
    '    *i*) command -v chcp.com >/dev/null 2>&1 && chcp.com 65001 >/dev/null 2>&1 ;;' \
    'esac')

# scriptencoding has to follow `set encoding`; cp1258 lets legacy
# Windows-Vietnamese files open correctly too.
VIMRC_BODY=$(cat <<'EOF'
set encoding=utf-8
scriptencoding utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,cp1258,cp1252,latin1
set termencoding=utf-8
set nobomb
set ambiwidth=single
EOF
)

INPUTRC_BODY=$(cat <<'EOF'
set input-meta on
set output-meta on
set convert-meta off
EOF
)

PS_BODY=$(cat <<'EOF'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
EOF
)

# ---------------------------------------------------------------- detection ---

ITEMS=()
STATUSES=()
DETAILS=()
NEED_COUNT=0

FIX_BASHRC=0
FIX_VIMRC=0
FIX_INPUTRC=0
FIX_MINTTYRC=0
FIX_GIT=0
FIX_REGISTRY=0
FIX_PSPROFILE=0
GIT_MISSING=()
PS_PROFILE=""

record() {
    ITEMS+=("$1")
    STATUSES+=("$2")
    DETAILS+=("$3")

    if [ "$2" = "FIX" ]; then
        NEED_COUNT=$((NEED_COUNT + 1))
    fi
}

check_bashrc() {
    if has_marker "$BASHRC" "$MARKER"; then
        record "shell locale" "OK" "~/.bashrc exports a UTF-8 locale"
        return
    fi

    FIX_BASHRC=1

    case "${LANG:-}" in
        "") record "shell locale" "FIX" "LANG is empty (C locale)" ;;
        *[Uu][Tt][Ff]*) record "shell locale" "FIX" "LANG=${LANG}, but ~/.bashrc does not set it" ;;
        *) record "shell locale" "FIX" "LANG=${LANG} is not UTF-8" ;;
    esac
}

check_codepage() {
    local cp
    cp="$(current_codepage)"

    if [ "$FIX_BASHRC" -eq 0 ]; then
        if [ "$cp" = "65001" ]; then
            record "console code page" "OK" "65001"
        else
            record "console code page" "OK" "${cp:-unknown} now, 65001 in a new shell"
        fi
        return
    fi

    record "console code page" "FIX" "${cp:-unknown} (want 65001)"
}

check_vimrc() {
    if has_marker "$VIMRC" "$VIM_MARKER"; then
        record "vim encoding" "OK" "~/.vimrc sets encoding=utf-8"
        return
    fi

    FIX_VIMRC=1

    if [ -f "$VIMRC" ]; then
        record "vim encoding" "FIX" "~/.vimrc does not set encoding"
    else
        record "vim encoding" "FIX" "~/.vimrc is missing"
    fi
}

check_inputrc() {
    if has_marker "$INPUTRC" "$MARKER"; then
        record "readline input" "OK" "~/.inputrc keeps 8-bit input"
        return
    fi

    FIX_INPUTRC=1

    if [ -f "$INPUTRC" ]; then
        record "readline input" "FIX" "~/.inputrc does not set input-meta"
    else
        record "readline input" "FIX" "~/.inputrc is missing"
    fi
}

check_minttyrc() {
    if grep -qxF "Charset=UTF-8" "$MINTTYRC" 2>/dev/null; then
        record "mintty charset" "OK" "Charset=UTF-8"
        return
    fi

    FIX_MINTTYRC=1

    if [ -f "$MINTTYRC" ]; then
        record "mintty charset" "FIX" "~/.minttyrc is not set to UTF-8"
    else
        record "mintty charset" "FIX" "~/.minttyrc is missing"
    fi
}

check_git() {
    local pair key want have

    if ! command -v git >/dev/null 2>&1; then
        record "git encoding" "OK" "git is not installed, skipping"
        return
    fi

    for pair in "${GIT_SETTINGS[@]}"; do
        key="${pair%%=*}"
        want="${pair#*=}"
        have="$(git config --global --get "$key" 2>/dev/null)"

        if [ "$have" != "$want" ]; then
            GIT_MISSING+=("$pair")
        fi
    done

    if [ "${#GIT_MISSING[@]}" -eq 0 ]; then
        record "git encoding" "OK" "quotepath and i18n.* are UTF-8"
        return
    fi

    FIX_GIT=1
    record "git encoding" "FIX" "${#GIT_MISSING[@]} setting(s) missing"
}

check_registry() {
    local out

    if [ "$DO_REGISTRY" -eq 0 ]; then
        record "HKCU\\Console code page" "SKIP" "--no-registry"
        return
    fi

    if ! command -v reg.exe >/dev/null 2>&1; then
        record "HKCU\\Console code page" "SKIP" "reg.exe not found"
        return
    fi

    out=$(reg.exe query "HKCU\\Console" //v CodePage 2>/dev/null | tr -d '\r')

    case "$out" in
        *0xfde9*) record "HKCU\\Console code page" "OK" "65001" ;;
        *)
            FIX_REGISTRY=1
            record "HKCU\\Console code page" "FIX" "not set to 65001"
            ;;
    esac
}

check_psprofile() {
    if [ "$DO_REGISTRY" -eq 0 ]; then
        record "PowerShell profile" "SKIP" "--no-registry"
        return
    fi

    PS_PROFILE="$(powershell_profile)"

    if [ -z "$PS_PROFILE" ]; then
        record "PowerShell profile" "SKIP" "powershell.exe not found"
        return
    fi

    if has_marker "$PS_PROFILE" "$MARKER"; then
        record "PowerShell profile" "OK" "already UTF-8"
        return
    fi

    FIX_PSPROFILE=1

    if [ -f "$PS_PROFILE" ]; then
        record "PowerShell profile" "FIX" "does not set UTF-8 encoding"
    else
        record "PowerShell profile" "FIX" "$(basename "$PS_PROFILE") is missing"
    fi
}

run_checks() {
    check_bashrc
    check_codepage
    check_vimrc
    check_inputrc
    check_minttyrc
    check_git
    check_registry
    check_psprofile
}

print_table() {
    local i width=0

    for i in "${ITEMS[@]}"; do
        if [ "${#i}" -gt "$width" ]; then
            width="${#i}"
        fi
    done

    echo ""
    echo "UTF-8 setup (Git Bash / Windows):"
    echo ""
    printf "  %-*s  %-6s  %s\n" "$width" "ITEM" "STATUS" "DETAIL"

    i=0
    while [ "$i" -lt "${#ITEMS[@]}" ]; do
        printf "  %-*s  %-6s  %s\n" \
            "$width" "${ITEMS[$i]}" "${STATUSES[$i]}" "${DETAILS[$i]}"
        i=$((i + 1))
    done
}

# ------------------------------------------------------------------ report ---

print_planned() {
    local pair

    echo ""
    echo "Planned changes:"

    if [ "$FIX_BASHRC" -eq 1 ]; then
        echo ""
        echo "  ${BASHRC} (append)"
        indent "$MARKER"
        indent "$BASHRC_BODY"
    fi

    if [ "$FIX_VIMRC" -eq 1 ]; then
        echo ""
        echo "  ${VIMRC} (append)"
        indent "$VIM_MARKER"
        indent "$VIMRC_BODY"
    fi

    if [ "$FIX_INPUTRC" -eq 1 ]; then
        echo ""
        echo "  ${INPUTRC} (append)"
        if [ ! -f "$INPUTRC" ] && [ -f /etc/inputrc ]; then
            echo "    \$include /etc/inputrc"
        fi
        indent "$MARKER"
        indent "$INPUTRC_BODY"
    fi

    if [ "$FIX_MINTTYRC" -eq 1 ]; then
        echo ""
        echo "  ${MINTTYRC} (set keys)"
        echo "    Charset=UTF-8"
        echo "    Locale=en_US"
        if ! ini_key_present "$MINTTYRC" "Font"; then
            echo "    Font=${CONSOLE_FONT}"
        fi
    fi

    if [ "$FIX_GIT" -eq 1 ]; then
        echo ""
        echo "  git config --global"
        for pair in "${GIT_MISSING[@]}"; do
            echo "    ${pair%%=*} ${pair#*=}"
        done
    fi

    if [ "$FIX_REGISTRY" -eq 1 ]; then
        echo ""
        echo "  HKCU\\Console (registry)"
        echo "    CodePage = 65001"
        echo "    FaceName = ${CONSOLE_FONT}"
    fi

    if [ "$FIX_PSPROFILE" -eq 1 ]; then
        echo ""
        echo "  ${PS_PROFILE} (append)"
        indent "$MARKER"
        indent "$PS_BODY"
    fi
}

# ------------------------------------------------------------------- apply ---

apply_bashrc() {
    [ "$FIX_BASHRC" -eq 1 ] || return 0

    if append_block "$BASHRC" "$MARKER" "$BASHRC_BODY"; then
        echo "  Updated ${BASHRC} (LANG/LC_ALL=${UTF8_LOCALE}, chcp 65001)"
    fi
}

apply_vimrc() {
    [ "$FIX_VIMRC" -eq 1 ] || return 0

    if append_block "$VIMRC" "$VIM_MARKER" "$VIMRC_BODY"; then
        echo "  Updated ${VIMRC} (encoding=utf-8)"
    fi
}

apply_inputrc() {
    [ "$FIX_INPUTRC" -eq 1 ] || return 0

    # A user ~/.inputrc replaces /etc/inputrc instead of extending it, so pull
    # the system defaults back in when creating the file from scratch.
    if [ ! -f "$INPUTRC" ] && [ -f /etc/inputrc ]; then
        echo '$include /etc/inputrc' > "$INPUTRC"
    fi

    if append_block "$INPUTRC" "$MARKER" "$INPUTRC_BODY"; then
        echo "  Updated ${INPUTRC} (8-bit input/output)"
    fi
}

apply_minttyrc() {
    [ "$FIX_MINTTYRC" -eq 1 ] || return 0

    set_ini_key "$MINTTYRC" "Charset" "UTF-8"
    set_ini_key "$MINTTYRC" "Locale" "en_US"

    if ! ini_key_present "$MINTTYRC" "Font"; then
        set_ini_key "$MINTTYRC" "Font" "$CONSOLE_FONT"
    fi

    echo "  Updated ${MINTTYRC} (Charset=UTF-8)"
}

apply_git() {
    local pair

    [ "$FIX_GIT" -eq 1 ] || return 0

    for pair in "${GIT_MISSING[@]}"; do
        git config --global "${pair%%=*}" "${pair#*=}" 2>/dev/null
    done

    echo "  Updated git --global (core.quotepath, i18n.*, gui.encoding)"
}

apply_registry() {
    local subkey

    [ "$FIX_REGISTRY" -eq 1 ] || return 0

    reg.exe add "HKCU\\Console" //v CodePage //t REG_DWORD //d 65001 //f >/dev/null 2>&1
    reg.exe add "HKCU\\Console" //v FaceName //t REG_SZ //d "$CONSOLE_FONT" //f >/dev/null 2>&1

    # Per-window-title subkeys (e.g. "Git Bash") override the root values.
    while read -r subkey; do
        [ -z "$subkey" ] && continue
        reg.exe add "$subkey" //v CodePage //t REG_DWORD //d 65001 //f >/dev/null 2>&1
    done <<< "$(reg.exe query "HKCU\\Console" 2>/dev/null | tr -d '\r' | grep -i '^HKEY_CURRENT_USER\\Console\\')"

    echo "  Updated HKCU\\Console (CodePage=65001, FaceName=${CONSOLE_FONT})"
}

apply_psprofile() {
    [ "$FIX_PSPROFILE" -eq 1 ] || return 0
    [ -n "$PS_PROFILE" ] || return 0

    mkdir -p "$(dirname "$PS_PROFILE")" 2>/dev/null

    if append_block "$PS_PROFILE" "$MARKER" "$PS_BODY"; then
        echo "  Updated ${PS_PROFILE} (UTF-8 console encoding)"
    fi
}

# -------------------------------------------------------------------- main ---

run_checks
print_table

if [ "$NEED_COUNT" -eq 0 ]; then
    echo ""
    echo "Everything is already set up for UTF-8."
    exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    echo "${NEED_COUNT} item(s) need fixing. Run: lazy fix.font"
    exit 1
fi

print_planned

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "Info: --dry-run, nothing was changed."
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    echo ""
    printf "Apply %s fix(es)? [y/N] " "$NEED_COUNT"

    ANSWER=""

    # Read from stdin so `echo y | lazy fix.font` works; fall back to the
    # terminal when stdin is closed or redirected from /dev/null.
    if ! read -r ANSWER; then
        if ! { read -r ANSWER < /dev/tty; } 2>/dev/null; then
            echo ""
            echo "Error: No input available for confirmation. Use -y to skip the prompt."
            exit 1
        fi
    fi

    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

echo ""

snapshot_existing "$BASHRC" "$VIMRC" "$INPUTRC" "$MINTTYRC" "$PS_PROFILE"

apply_bashrc
apply_vimrc
apply_inputrc
apply_minttyrc
apply_git
apply_registry
apply_psprofile

echo ""
echo "Done. Restart Git Bash (or run: source ~/.bashrc)"
echo ""
echo "Then this line should read correctly:  Tiếng Việt — ăâđêôơư ạảãáà"

if [ -n "${WT_SESSION:-}" ]; then
    echo ""
    echo "Note: this session runs in Windows Terminal, which ignores ~/.minttyrc."
    echo "      If text is still wrong there, set the profile font to '${CONSOLE_FONT}'"
    echo "      in Settings -> Profiles -> Appearance."
fi
