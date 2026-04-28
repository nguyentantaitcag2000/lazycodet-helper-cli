#!/bin/bash

echo "Installing lazy tool..."

# Generate a timestamp to bypass GitHub CDN cache
TIME_STAMP=$(date +%s)
URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh?v=$TIME_STAMP"

# Download the file to /usr/local/bin/lazy
# -f: Fail silently on server errors (like 404)
# -sSL: Silent mode, follow redirects, and show errors
sudo curl -f -sSL "$URL" -o /usr/local/bin/lazy

if [ $? -eq 0 ]; then
    sudo chmod +x /usr/local/bin/lazy
    echo "------------------------------------------"
    echo "Installation successful! Try running: lazy branch.history"
else
    echo "------------------------------------------"
    echo "Error: Failed to download the file."
    echo "Please check your internet connection or the repository URL."
fi
