#!/bin/bash

# URL to the raw source on GitHub
REPO_URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh"
INSTALL_PATH="/usr/local/bin/lazy"

case "$1" in
    "branch.history")
        # 1. Check if current directory is a Git repository
        if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
            echo "Error: This directory is not a Git repository."
            exit 1
        fi

        # 2. Check if fzf is installed
        if ! command -v fzf >/dev/null 2>&1; then
            echo "Error: fzf is not installed."
            echo ""
            echo "Install:"
            echo "  Ubuntu/Debian : sudo apt install fzf"
            echo "  Arch Linux    : sudo pacman -S fzf"
            echo "  MacOS         : brew install fzf"
            exit 1
        fi

        # 3. Get current branch
        CURRENT_BRANCH=$(git branch --show-current)

        # 4. Get checkout branch history
        BRANCH_HISTORY=$(
            GIT_PAGER=cat git reflog show --date=format:'%Y-%m-%d %H:%M:%S' | \
            grep 'checkout: moving from' | \
            awk -v current="$CURRENT_BRANCH" '
            {
                branch = ""
                date = $1 " " $2

                for(i=1;i<=NF;i++) {
                    if($i=="to") {
                        branch=$(i+1)
                        break
                    }
                }

                if(branch != "") {

                    marker = "○"

                    if(branch == current) {
                        marker = "●"
                    }

                    print marker " " branch " | " date
                }
            }' | \
            awk '!seen[$2]++'
        )

        # 5. Check empty history
        if [ -z "$BRANCH_HISTORY" ]; then
            echo "Info: No checkout history found in this repository."
            exit 0
        fi

        echo ""
        echo "Current branch: $CURRENT_BRANCH"
        echo "Hint: Press ENTER to checkout selected branch"
        echo "Hint: Press CTRL+C or ESC to cancel"
        echo ""

        # 6. Open interactive selector
        SELECTED=$(
            echo "$BRANCH_HISTORY" | \
            fzf \
                --height=80% \
                --layout=reverse \
                --border \
                --prompt="Branch History > " \
                --header="ENTER = checkout branch" \
                --preview='echo {}' \
                --preview-window=hidden
        )

        # 7. Exit if nothing selected
        if [ -z "$SELECTED" ]; then
            echo "Cancelled."
            exit 0
        fi

        # 8. Extract branch name
        TARGET_BRANCH=$(echo "$SELECTED" | awk '{print $2}')

        # 9. Prevent checkout same branch
        if [ "$TARGET_BRANCH" = "$CURRENT_BRANCH" ]; then
            echo "Already on branch: $CURRENT_BRANCH"
            exit 0
        fi

        echo ""
        echo "Checking out to branch: $TARGET_BRANCH"
        echo ""

        # 10. Checkout branch
        git checkout "$TARGET_BRANCH"
        ;;

    "update")
        echo "Checking for updates..."

        # Use timestamp to bypass GitHub CDN cache
        sudo curl -sSL "${REPO_URL}?v=$(date +%s)" -o $INSTALL_PATH

        sudo chmod +x $INSTALL_PATH

        echo "Successfully updated to the latest version!"
        ;;

    *)
        echo "Usage: lazy [branch.history | update]"
        ;;
esac