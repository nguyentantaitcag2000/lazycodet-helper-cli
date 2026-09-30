#!/bin/bash
# Shared branch and description helpers for `lazy branch` and
# `lazy branch.description`. This file is sourced; callers decide when to exit.
# It sticks to Bash 3.2 so the stock macOS shell can run it.
# The c_* color variables are read by the commands that source this file.
# shellcheck disable=SC2034

BRANCH_NAMES=()
BRANCH_DESC_KEYS=()
BRANCH_DESC_VALUES=()
BRANCH_CURRENT=""
BRANCH_DESC=""

c_label=""; c_name=""; c_current=""; c_desc=""; c_dim=""
c_ok=""; c_warn=""; c_err=""; c_reset=""

# Sets the color variables. "auto" colors only a terminal and honors NO_COLOR;
# "always" and "never" are explicit and win over the environment.
branch_colors() {
    local when="${1:-auto}"
    local enabled=0

    case "$when" in
        always) enabled=1 ;;
        never) enabled=0 ;;
        *)
            if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
                enabled=1
            fi
            ;;
    esac

    if [ "$enabled" -eq 1 ]; then
        c_label=$'\033[2m'; c_name=$'\033[1;36m'; c_current=$'\033[1;32m'
        c_desc=$'\033[33m'; c_dim=$'\033[2m'; c_ok=$'\033[32m'
        c_warn=$'\033[33m'; c_err=$'\033[31m'; c_reset=$'\033[0m'
    else
        c_label=""; c_name=""; c_current=""; c_desc=""; c_dim=""
        c_ok=""; c_warn=""; c_err=""; c_reset=""
    fi
}

# Drops surrounding blank lines and whitespace. `git branch --edit-description`
# always stores a final newline, and a Windows editor may leave CRs behind.
branch_trim() {
    local value="$1"

    value=${value//$'\r'/}
    while :; do
        case "$value" in
            *$'\n' | *' ' | *$'\t') value=${value%?} ;;
            *) break ;;
        esac
    done
    while :; do
        case "$value" in
            $'\n'* | ' '* | $'\t'*) value=${value#?} ;;
            *) break ;;
        esac
    done
    BRANCH_TRIMMED="$value"
}

# Loads every local branch and every branch description with one Git call
# each, so listing many branches never starts one `git config` per branch.
branch_load() {
    local name
    local record
    local key
    local value

    BRANCH_NAMES=()
    BRANCH_DESC_KEYS=()
    BRANCH_DESC_VALUES=()
    BRANCH_CURRENT=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)

    while IFS= read -r name; do
        if [ -n "$name" ]; then
            BRANCH_NAMES+=("$name")
        fi
    done < <(git for-each-ref --format='%(refname:lstrip=2)' refs/heads/)

    # -z ends each entry with NUL and separates the key from its value with a
    # newline, so multi-line descriptions and dotted branch names survive.
    while IFS= read -r -d '' record; do
        key=${record%%$'\n'*}
        value=""
        if [ "$key" != "$record" ]; then
            value=${record#*$'\n'}
        fi
        key=${key#branch.}
        key=${key%.description}
        branch_trim "$value"
        BRANCH_DESC_KEYS+=("$key")
        BRANCH_DESC_VALUES+=("$BRANCH_TRIMMED")
    done < <(git config -z --get-regexp '^branch\..*\.description$' 2>/dev/null)
}

branch_exists() {
    local name

    [ "${#BRANCH_NAMES[@]}" -gt 0 ] || return 1
    for name in "${BRANCH_NAMES[@]}"; do
        if [ "$name" = "$1" ]; then
            return 0
        fi
    done
    return 1
}

# Sets BRANCH_DESC to the loaded description of $1 (empty when it has none).
# A global instead of stdout keeps callers free of a subshell per branch.
branch_description_of() {
    local i

    BRANCH_DESC=""
    [ "${#BRANCH_DESC_KEYS[@]}" -gt 0 ] || return 1
    for i in "${!BRANCH_DESC_KEYS[@]}"; do
        if [ "${BRANCH_DESC_KEYS[$i]}" = "$1" ]; then
            BRANCH_DESC="${BRANCH_DESC_VALUES[$i]}"
            [ -n "$BRANCH_DESC" ]
            return
        fi
    done
    return 1
}

branch_name_width() {
    local name

    BRANCH_WIDTH=0
    [ "${#BRANCH_NAMES[@]}" -gt 0 ] || return 0
    for name in "${BRANCH_NAMES[@]}"; do
        if [ "${#name}" -gt "$BRANCH_WIDTH" ]; then
            BRANCH_WIDTH="${#name}"
        fi
    done
}

# Prints one list row: the marker, the padded name, then the description.
# Continuation lines of a multi-line description line up under the first.
# Padding is applied outside the color codes, which have no printed width.
branch_print_row() {
    local name="$1"
    local width="$2"
    local marker="  "
    local color="$c_name"
    local line
    local first=1

    if [ "$name" = "$BRANCH_CURRENT" ]; then
        marker="● "
        color="$c_current"
    fi

    if ! branch_description_of "$name"; then
        printf '%s%s%s%s\n' "$marker" "$color" "$name" "$c_reset"
        return 0
    fi

    while IFS= read -r line; do
        if [ "$first" -eq 1 ]; then
            printf '%s%s%s%s%*s  %s%s%s\n' \
                "$marker" "$color" "$name" "$c_reset" \
                "$((width - ${#name}))" "" \
                "$c_desc" "$line" "$c_reset"
            first=0
        else
            printf '%*s%s%s%s\n' "$((width + 4))" "" "$c_desc" "$line" "$c_reset"
        fi
    done <<EOF
$BRANCH_DESC
EOF
}
