#!/bin/bash

# URL to the raw source on GitHub
REPO_URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh"
INSTALL_PATH="/usr/local/bin/lazy"

case "$1" in
    "branch.history")
        # 1. Check if the current directory is a Git repository
        if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
            echo "Error: This directory is not a Git repository."
            exit 1
        fi

        # 2. Fetch data and store it in a variable
        data=$(GIT_PAGER=cat git reflog show --date=format:'%Y-%m-%d %H:%M:%S' | \
               grep 'checkout: moving from' | \
               awk -F' ' '{date=$2" "$3; for(i=1;i<=NF;i++) if($i=="to") {print "["date"] - "$ (i+1); next}}' | \
               uniq)

        # 3. Check if the history is empty
        if [ -z "$data" ]; then
            echo "Info: No checkout history found in this repository."
        else
            # Display output via less with:
            # -F (quit if content fits on one screen)
            # -X (keep content on screen after exit)
            echo "$data" | less -FX
        fi
        ;;

    "update")
        echo "Checking for updates..."
        # Use a timestamp to bypass GitHub CDN cache
        sudo curl -sSL "${REPO_URL}?v=$(date +%s)" -o $INSTALL_PATH
        sudo chmod +x $INSTALL_PATH
        echo "Successfully updated to the latest version!"
        ;;

    *)
        echo "Usage: lazy [branch.history | update]"
        ;;
esac
