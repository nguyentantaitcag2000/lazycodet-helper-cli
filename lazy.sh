#!/bin/bash

REPO_URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh"
INSTALL_PATH="/usr/local/bin/lazy"

case "$1" in

    "branch.history")

        # Check git repo
        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Error: This directory is not a Git repository."
            exit 1
        fi

        # Check fzf
        if ! command -v fzf >/dev/null 2>&1; then
            echo "Error: fzf is not installed."
            echo ""
            echo "Install:"
            echo "  Ubuntu/Debian : sudo apt install fzf"
            echo "  Arch Linux    : sudo pacman -S fzf"
            echo "  MacOS         : brew install fzf"
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
                --prompt="Branch History > " \
                --header="ENTER = checkout branch"
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

        echo ""
        echo "Checking out: $TARGET_BRANCH"
        echo ""

        git checkout "$TARGET_BRANCH"

        ;;

    "update")

        echo "Checking for updates..."

        if sudo curl -f -sSL "${REPO_URL}?v=$(date +%s)" -o "$INSTALL_PATH"; then
            sudo chmod +x "$INSTALL_PATH"
            echo "Successfully updated to the latest version!"
        else
            echo "Update failed!"
            exit 1
        fi

        ;;

    *)

        echo "Usage:"
        echo "  lazy branch.history"
        echo "  lazy update"

        ;;

esac