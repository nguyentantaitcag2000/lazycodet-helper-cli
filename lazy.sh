#!/bin/bash

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

COMMAND_DIR="$BASE_DIR/commands"

COMMAND="$1"

# Each entry is "<invocation>|<description>".
# Columns are aligned from the longest invocation so adding a command
# never leaves the descriptions ragged.
COMMANDS=(
    "lazy branch.history|Pick a recently checked-out branch and switch to it (requires fzf)"
    "lazy kill <port> [-y]|List the processes listening on <port> and kill them"
    "lazy update|Update lazy to the latest version from origin"
)

print_usage() {
    local entry
    local invocation
    local width=0
    local c_title=""
    local c_cmd=""
    local c_desc=""
    local c_reset=""

    # Colors only when writing to a terminal; honor NO_COLOR.
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        c_title=$'\033[1m'
        c_cmd=$'\033[1;36m'
        c_desc=$'\033[2m'
        c_reset=$'\033[0m'
    fi

    for entry in "${COMMANDS[@]}"; do
        invocation="${entry%%|*}"
        if [ "${#invocation}" -gt "$width" ]; then
            width="${#invocation}"
        fi
    done

    printf '%sUsage:%s\n' "$c_title" "$c_reset"
    for entry in "${COMMANDS[@]}"; do
        invocation="${entry%%|*}"
        # Pad outside the color codes: escapes have no printed width,
        # so letting printf pad a colored string would skew the columns.
        printf '  %s%s%s%*s  %s%s%s\n' \
            "$c_cmd" "$invocation" "$c_reset" \
            "$((width - ${#invocation}))" "" \
            "$c_desc" "${entry#*|}" "$c_reset"
    done
}

if [ -z "$COMMAND" ]; then
    print_usage
    exit 1
fi

shift

COMMAND_FILE="$COMMAND_DIR/$COMMAND.sh"

if [ ! -f "$COMMAND_FILE" ]; then
    echo "Error: Command not found -> $COMMAND"
    echo ""
    print_usage
    exit 1
fi

bash "$COMMAND_FILE" "$@"
