#!/bin/bash
# List local branches next to their descriptions, colored so a branch name
# and its description are easy to tell apart.

# The c_* color variables are assigned by lib/branch-common.sh.
# shellcheck disable=SC2154

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/branch-common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/branch-common.sh"

usage() {
    echo "Usage:"
    echo "  lazy branch [--color[=<when>]]"
    echo ""
    echo "List local branches with the description set by"
    echo "'git branch --edit-description' or 'lazy branch.description'."
    echo "The current branch is marked with ●."
    echo ""
    echo "Options:"
    echo "  --color[=<when>]  Color output: auto (default), always, or never"
    echo "  --no-color        Same as --color=never"
    echo "  -h, --help        Show this help"
}

COLOR_WHEN="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        --color) COLOR_WHEN="always" ;;
        --color=*)
            COLOR_WHEN="${1#--color=}"
            case "$COLOR_WHEN" in
                auto|always|never) ;;
                *) echo "Error: --color must be auto, always, or never -> $COLOR_WHEN" >&2; exit 1 ;;
            esac
            ;;
        --no-color) COLOR_WHEN="never" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: Unexpected argument -> $1" >&2; echo ""; usage; exit 1 ;;
    esac
    shift
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: This directory is not a Git repository." >&2
    exit 1
fi

branch_colors "$COLOR_WHEN"
branch_load

if [ "${#BRANCH_NAMES[@]}" -eq 0 ]; then
    echo "Info: No local branches found."
    exit 0
fi

branch_name_width
for name in "${BRANCH_NAMES[@]}"; do
    branch_print_row "$name" "$BRANCH_WIDTH"
done

# The hint is for a person at a terminal; piped output stays a plain list.
if [ -t 1 ]; then
    echo ""
    printf '%sEdit a description: lazy branch.description [branch]%s\n' "$c_dim" "$c_reset"
fi
