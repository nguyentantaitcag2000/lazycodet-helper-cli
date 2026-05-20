#!/bin/bash

set -e

echo "Installing lazy tool..."

REPO_URL="https://github.com/nguyentantaitcag2000/lazycodet-helper-cli.git"
INSTALL_DIR="/opt/lazy"

# Remove old install
sudo rm -rf "$INSTALL_DIR"

# Clone latest source
sudo git clone "$REPO_URL" "$INSTALL_DIR"

# Make executable
sudo chmod +x "$INSTALL_DIR/lazy.sh"
sudo chmod +x "$INSTALL_DIR/commands/"*.sh

# Create symlink
sudo ln -sf "$INSTALL_DIR/lazy.sh" /usr/local/bin/lazy

echo "------------------------------------------"
echo "Installation successful!"
echo "Run:"
echo "  lazy branch.history"
