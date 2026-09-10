#!/bin/bash

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_PATH" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
    LINK_TARGET="$(readlink "$SCRIPT_PATH")"
    case "$LINK_TARGET" in
        /*) SCRIPT_PATH="$LINK_TARGET" ;;
        *) SCRIPT_PATH="${SCRIPT_DIR}/${LINK_TARGET}" ;;
    esac
done
BASE_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"

COMMAND_DIR="$BASE_DIR/commands"

# shellcheck source=lib/platform.sh
source "$BASE_DIR/lib/platform.sh"

PLATFORM="$(platform_id)"

if [ "$PLATFORM" = "unsupported" ]; then
    echo "Error: Unsupported operating system -> $(uname -s 2>/dev/null || echo unknown)" >&2
    exit 1
fi

COMMAND="$1"

# Each entry is "<name>|<platforms>|<invocation>|<description>". Keep platform
# availability explicit: a platform-specific command must not leak into another
# platform's help just because its script exists in commands/.
# Columns are aligned from the longest invocation so adding a command
# never leaves the descriptions ragged.
COMMANDS=(
    "agent.sync|linux,wsl,git-bash,macos|lazy agent.sync [project] [--check]|Link AGENTS.md and .agents/skills to their Claude sources"
    "branch.history|linux,wsl,git-bash,macos|lazy branch.history|Pick a recently checked-out branch and switch to it (requires fzf)"
    "claude.auth|git-bash|lazy claude.auth [distro]|Sync the Claude Code login between Windows and a WSL distro"
    "fix.font|git-bash|lazy fix.font [--check]|Fix garbled Vietnamese/UTF-8 text on Windows (locale, vim, console)"
    "git.remember|linux,wsl,git-bash,macos|lazy git.remember [remote] [-f]|Store this repo's Git username/password so Git stops asking"
    "kill|linux,wsl,git-bash,macos|lazy kill <port> [-y]|Kill what holds <port> on the scopes available here"
    "update|linux,wsl,git-bash,macos|lazy update|Update lazy to the latest version from origin"
)

platform_supports() {
    case ",$1," in
        *,"$PLATFORM",*) return 0 ;;
        *) return 1 ;;
    esac
}

print_usage() {
    local entry
    local name
    local platforms
    local invocation
    local description
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
        IFS='|' read -r name platforms invocation description <<EOF
$entry
EOF
        platform_supports "$platforms" || continue
        if [ "${#invocation}" -gt "$width" ]; then
            width="${#invocation}"
        fi
    done

    printf '%sUsage:%s\n' "$c_title" "$c_reset"
    for entry in "${COMMANDS[@]}"; do
        IFS='|' read -r name platforms invocation description <<EOF
$entry
EOF
        platform_supports "$platforms" || continue
        # Pad outside the color codes: escapes have no printed width,
        # so letting printf pad a colored string would skew the columns.
        printf '  %s%s%s%*s  %s%s%s\n' \
            "$c_cmd" "$invocation" "$c_reset" \
            "$((width - ${#invocation}))" "" \
            "$c_desc" "$description" "$c_reset"
    done
}

if [ -z "$COMMAND" ]; then
    print_usage
    exit 1
fi

shift

COMMAND_FILE="$COMMAND_DIR/$COMMAND.sh"

COMMAND_PLATFORMS=""
for entry in "${COMMANDS[@]}"; do
    IFS='|' read -r name platforms invocation description <<EOF
$entry
EOF
    if [ "$name" = "$COMMAND" ]; then
        COMMAND_PLATFORMS="$platforms"
        break
    fi
done

if [ -z "$COMMAND_PLATFORMS" ] || [ ! -f "$COMMAND_FILE" ]; then
    echo "Error: Command not found -> $COMMAND"
    echo ""
    print_usage
    exit 1
fi

if ! platform_supports "$COMMAND_PLATFORMS"; then
    echo "Error: Command 'lazy $COMMAND' is not available on $(platform_label "$PLATFORM")."
    echo ""
    print_usage
    exit 1
fi

# exec, not a child bash: `lazy update` rewrites this very file, and bash reads
# scripts lazily. Returning here after the rewrite would make bash resume
# parsing at a stale byte offset ("unexpected EOF"), even though the command
# itself succeeded. Replacing the process means nothing reads this file again.
exec bash "$COMMAND_FILE" "$@"
