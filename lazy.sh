#!/bin/bash

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

COMMAND_DIR="$BASE_DIR/commands"

COMMAND="$1"

# Each entry is "<invocation>|<description>".
# Columns are aligned from the longest invocation so adding a command
# never leaves the descriptions ragged.
COMMANDS=(
    "lazy agent.sync [project] [--check]|Link AGENTS.md and .agents/skills to their Claude sources"
    "lazy branch.history|Pick a recently checked-out branch and switch to it (requires fzf)"
    "lazy claude.auth [distro]|Copy this machine's Claude Code login into a WSL distro"
    "lazy fix.font [--check]|Fix garbled Vietnamese/UTF-8 text on Windows (locale, vim, console)"
    "lazy git.remember [remote] [-f]|Store this repo's Git username/password so Git stops asking"
    "lazy kill <port> [-y]|Kill what holds <port>, including other WSL distros and Windows"
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

# exec, not a child bash: `lazy update` rewrites this very file, and bash reads
# scripts lazily. Returning here after the rewrite would make bash resume
# parsing at a stale byte offset ("unexpected EOF"), even though the command
# itself succeeded. Replacing the process means nothing reads this file again.
exec bash "$COMMAND_FILE" "$@"
