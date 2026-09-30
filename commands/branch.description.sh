#!/bin/bash
# Show one branch's description, then edit, set, or clear it from an fzf menu
# or directly with a flag.

# The c_* color variables are assigned by lib/branch-common.sh.
# shellcheck disable=SC2154

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/branch-common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/branch-common.sh"

usage() {
    echo "Usage:"
    echo "  lazy branch.description [branch] [options]"
    echo ""
    echo "Show the description of <branch> (default: the current branch), then"
    echo "open a menu to edit it in your Git editor, type a one-line description,"
    echo "clear it, or choose another branch. The menu needs fzf."
    echo ""
    echo "Options:"
    echo "  -e, --edit        Edit the description in your Git editor"
    echo "  -s, --set <text>  Set the description to <text>"
    echo "  -c, --clear       Remove the description"
    echo "  -p, --print       Print the description and exit, without the menu"
    echo "  -h, --help        Show this help"
}

ACTION="menu"
TARGET=""
SET_TEXT=""

set_action() {
    if [ "$ACTION" != "menu" ]; then
        echo "Error: Use only one of --edit, --set, --clear, or --print." >&2
        exit 1
    fi
    ACTION="$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -e|--edit) set_action edit ;;
        -s|--set)
            set_action set
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --set needs a description." >&2
                exit 1
            fi
            SET_TEXT="$1"
            ;;
        --set=*) set_action set; SET_TEXT="${1#--set=}" ;;
        -c|--clear) set_action clear ;;
        -p|--print) set_action print ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1" >&2; echo ""; usage; exit 1 ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "Error: Only one branch name is accepted -> $1" >&2
                exit 1
            fi
            TARGET="$1"
            ;;
    esac
    shift
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: This directory is not a Git repository." >&2
    exit 1
fi

branch_colors auto

say_ok()   { printf '%s%s%s\n' "$c_ok" "$1" "$c_reset"; }
say_warn() { printf '%s%s%s\n' "$c_warn" "$1" "$c_reset"; }
say_dim()  { printf '%s%s%s\n' "$c_dim" "$1" "$c_reset"; }
say_err()  { printf '%sError: %s%s\n' "$c_err" "$1" "$c_reset" >&2; }

HAVE_FZF=0
if command -v fzf >/dev/null 2>&1; then
    HAVE_FZF=1
fi

# ------------------------------------------------------------------- display

show_block() {
    local color="$c_name"
    local suffix=""
    local line
    local first=1

    if [ "$TARGET" = "$BRANCH_CURRENT" ]; then
        color="$c_current"
        suffix=" (current)"
    fi

    printf '%sBranch%s       %s%s%s%s%s%s\n' \
        "$c_label" "$c_reset" "$color" "$TARGET" "$c_reset" "$c_dim" "$suffix" "$c_reset"

    if ! branch_description_of "$TARGET"; then
        printf '%sDescription%s  %s(none)%s\n' "$c_label" "$c_reset" "$c_dim" "$c_reset"
        return 0
    fi

    while IFS= read -r line; do
        if [ "$first" -eq 1 ]; then
            printf '%sDescription%s  %s%s%s\n' "$c_label" "$c_reset" "$c_desc" "$line" "$c_reset"
            first=0
        else
            printf '             %s%s%s\n' "$c_desc" "$line" "$c_reset"
        fi
    done <<EOF
$BRANCH_DESC
EOF
}

report_change() {
    if [ "$1" = "$2" ]; then
        say_dim "No change."
    elif [ -z "$2" ]; then
        say_ok "Description removed from $TARGET."
    else
        say_ok "Description saved for $TARGET."
    fi
}

# ------------------------------------------------------------------- actions

do_edit() {
    local before

    branch_description_of "$TARGET"
    before="$BRANCH_DESC"

    # Git opens its own editor (core.editor / GIT_EDITOR) with a commented
    # template; saving an empty file removes the description.
    if ! git branch --edit-description "$TARGET"; then
        say_err "The editor did not finish; the description was not changed."
        return 1
    fi

    branch_load
    branch_description_of "$TARGET"
    report_change "$before" "$BRANCH_DESC"
}

do_set() {
    local before
    local text

    branch_trim "$1"
    text="$BRANCH_TRIMMED"
    if [ -z "$text" ]; then
        say_err "A description cannot be empty. Use --clear to remove it."
        return 1
    fi

    branch_description_of "$TARGET"
    before="$BRANCH_DESC"

    if ! git config "branch.$TARGET.description" "$text"; then
        say_err "Could not save the description of $TARGET."
        return 1
    fi

    branch_load
    branch_description_of "$TARGET"
    report_change "$before" "$BRANCH_DESC"
}

do_clear() {
    local before

    branch_description_of "$TARGET"
    before="$BRANCH_DESC"
    if [ -z "$before" ]; then
        say_dim "$TARGET has no description."
        return 0
    fi

    if ! git config --unset-all "branch.$TARGET.description"; then
        say_err "Could not remove the description of $TARGET."
        return 1
    fi

    branch_load
    branch_description_of "$TARGET"
    report_change "$before" "$BRANCH_DESC"
}

do_quick() {
    local before
    local text=""

    branch_description_of "$TARGET"
    before="$BRANCH_DESC"

    case "$before" in
        *$'\n'*)
            say_warn "This replaces the whole multi-line description. Use Edit to change it line by line."
            before=""
            ;;
    esac

    # Bash 4 can prefill the line with the current text; Bash 3.2 (stock
    # macOS) cannot, so the user types it from scratch there.
    if [ "${BASH_VERSINFO[0]}" -ge 4 ] && [ -n "$before" ]; then
        read -r -e -i "$before" -p "Description: " text || { echo ""; say_dim "No change."; return 0; }
    else
        read -r -e -p "Description: " text || { echo ""; say_dim "No change."; return 0; }
    fi

    branch_trim "$text"
    if [ -z "$BRANCH_TRIMMED" ]; then
        say_dim "No change. Use Clear to remove the description."
        return 0
    fi

    do_set "$BRANCH_TRIMMED"
}

confirm() {
    local answer=""

    printf '%s [y/N] ' "$1"
    read -r answer || { echo ""; return 1; }
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
    esac
    return 1
}

# Rows are built before fzf starts so moving the cursor never runs Git. The
# first tab-separated field is the branch name and stays hidden.
pick_branch() {
    local rows=()
    local row
    local name
    local marker
    local color
    local desc
    local selected

    branch_name_width
    for name in "${BRANCH_NAMES[@]}"; do
        marker="  "
        color="$c_name"
        if [ "$name" = "$BRANCH_CURRENT" ]; then
            marker="● "
            color="$c_current"
        fi

        desc=""
        if branch_description_of "$name"; then
            desc="${BRANCH_DESC%%$'\n'*}"
            if [ "$desc" != "$BRANCH_DESC" ]; then
                desc="$desc …"
            fi
            desc="${desc//$'\t'/ }"
        fi

        printf -v row '%s\t%s%s%s%s%*s  %s%s%s' \
            "$name" "$marker" "$color" "$name" "$c_reset" \
            "$((BRANCH_WIDTH - ${#name}))" "" "$c_desc" "$desc" "$c_reset"
        rows+=("$row")
    done

    selected=$(
        printf '%s\n' "${rows[@]}" |
        fzf \
            --ansi \
            --height=80% \
            --layout=reverse \
            --border \
            --prompt="Branch > " \
            --header="ENTER = choose   ESC = back" \
            --delimiter=$'\t' \
            --with-nth=2..
    ) || return 1

    selected="${selected%%$'\t'*}"
    [ -n "$selected" ] || return 1
    TARGET="$selected"
}

run_menu() {
    local rows
    local choice
    local action

    while :; do
        echo ""
        show_block
        echo ""

        rows=(
            "edit"$'\t'"Edit description   open it in your Git editor"
            "quick"$'\t'"Quick edit         type a one-line description here"
        )
        if branch_description_of "$TARGET"; then
            rows+=("clear"$'\t'"Clear description")
        fi
        if [ "${#BRANCH_NAMES[@]}" -gt 1 ]; then
            rows+=("switch"$'\t'"Choose another branch")
        fi
        rows+=("quit"$'\t'"Quit")

        choice=$(
            printf '%s\n' "${rows[@]}" |
            fzf \
                --height=11 \
                --layout=reverse \
                --border \
                --prompt="Action > " \
                --header="ENTER = run   ESC = quit" \
                --delimiter=$'\t' \
                --with-nth=2
        ) || choice=""
        action="${choice%%$'\t'*}"

        case "$action" in
            edit) do_edit ;;
            quick) do_quick ;;
            clear)
                if confirm "Remove the description of $TARGET?"; then
                    do_clear
                else
                    say_dim "Kept the description."
                fi
                ;;
            switch) pick_branch || say_dim "Still on $TARGET." ;;
            *) return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------- main

branch_load

if [ "${#BRANCH_NAMES[@]}" -eq 0 ]; then
    echo "Info: No local branches found. Make a first commit before describing a branch."
    exit 0
fi

if [ -z "$TARGET" ]; then
    TARGET="$BRANCH_CURRENT"
    if [ -z "$TARGET" ] || ! branch_exists "$TARGET"; then
        if [ "$ACTION" = "menu" ] && [ "$HAVE_FZF" -eq 1 ]; then
            pick_branch || { echo "Cancelled."; exit 0; }
        else
            say_err "HEAD is not on a local branch. Pass one: lazy branch.description <branch>"
            exit 1
        fi
    fi
fi

if ! branch_exists "$TARGET"; then
    say_err "Local branch not found -> $TARGET"
    exit 1
fi

case "$ACTION" in
    print) show_block ;;
    edit) do_edit || exit 1; show_block ;;
    set) do_set "$SET_TEXT" || exit 1; show_block ;;
    clear) do_clear || exit 1; show_block ;;
    menu)
        if [ "$HAVE_FZF" -eq 0 ]; then
            show_block
            echo ""
            echo "Info: Install fzf for the action menu, or use --edit, --set <text>, or --clear."
            exit 0
        fi
        run_menu
        ;;
esac
