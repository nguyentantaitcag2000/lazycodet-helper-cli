#!/bin/bash

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: This directory is not a Git repository."
    exit 1
fi

if ! command -v fzf >/dev/null 2>&1; then
    echo "Error: fzf is not installed."
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)

BRANCH_HISTORY=$(
    GIT_PAGER=cat git reflog show --date=format:'%Y-%m-%d %H:%M:%S' |
    grep 'checkout: moving from' |
    awk -v current="$CURRENT_BRANCH" '
    {
        branch=""
        date=$1" "$2

        for(i=1;i<=NF;i++) {
            if($i=="to") {
                branch=$(i+1)
                break
            }
        }

        if(branch!="") {

            marker="○"

            if(branch==current) {
                marker="●"
            }

            print marker" "branch" | "date
        }
    }
    ' |
    awk '!seen[$2]++'
)

if [ -z "$BRANCH_HISTORY" ]; then
    echo "Info: No checkout history found."
    exit 0
fi

echo ""
echo "Current branch: $CURRENT_BRANCH"
echo "ENTER = checkout branch"
echo "ESC   = cancel"
echo ""

SELECTED=$(
    echo "$BRANCH_HISTORY" |
    fzf \
        --height=80% \
        --layout=reverse \
        --border \
        --prompt="Branch History > "
)

if [ -z "$SELECTED" ]; then
    echo "Cancelled."
    exit 0
fi

TARGET_BRANCH=$(echo "$SELECTED" | awk '{print $2}')

if [ "$TARGET_BRANCH" = "$CURRENT_BRANCH" ]; then
    echo "Already on branch: $CURRENT_BRANCH"
    exit 0
fi

git checkout "$TARGET_BRANCH"