#!/bin/bash

REPO_URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh"
INSTALL_PATH="/usr/local/bin/lazy"

echo "Checking for updates..."

if sudo curl -f -sSL "${REPO_URL}?v=$(date +%s)" -o "$INSTALL_PATH"; then
    sudo chmod +x "$INSTALL_PATH"
    echo "Successfully updated!"
else
    echo "Update failed!"
    exit 1
fi