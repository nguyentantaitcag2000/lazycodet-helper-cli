#!/bin/bash

set -e

echo "Installing lazy tool..."

REPO_URL="https://github.com/nguyentantaitcag2000/lazycodet-helper-cli.git"

is_git_bash() {
    if [ -n "${MSYSTEM:-}" ]; then
        return 0
    fi

    case "${OSTYPE:-}" in
        msys*|cygwin*) return 0 ;;
    esac

    case "$(uname -s 2>/dev/null || true)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac

    return 1
}

is_macos() {
    [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]
}

is_linux() {
    [ "$(uname -s 2>/dev/null || true)" = "Linux" ]
}

install_linux() {
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
    echo "  lazy kill <port>"
}

install_macos() {
    local install_dir="/usr/local/lib/lazy"
    local command_path="/usr/local/bin/lazy"

    echo "Detected macOS."

    # Keep the managed checkout outside Homebrew so Intel and Apple Silicon use
    # the same location. The public command remains on the standard PATH.
    sudo mkdir -p /usr/local/lib /usr/local/bin
    sudo rm -rf "$install_dir"
    sudo git clone "$REPO_URL" "$install_dir"

    sudo chmod +x "$install_dir/lazy.sh"
    sudo chmod +x "$install_dir/commands/"*.sh
    sudo ln -sf "$install_dir/lazy.sh" "$command_path"

    if ! command -v fzf >/dev/null 2>&1; then
        echo ""
        echo "Warning: fzf is not installed (required for: lazy branch.history)"
        echo "  Homebrew: brew install fzf"
        echo "  Manual:   https://github.com/junegunn/fzf/releases"
    fi

    echo "------------------------------------------"
    echo "Installation successful!"
    echo "Install dir: ${install_dir}"
    echo "Command:     ${command_path}"
    echo ""
    echo "Run:"
    echo "  lazy branch.history"
    echo "  lazy kill <port>"
    echo "  lazy update"
}

ensure_git_bash_path() {
    local bin_dir="$1"
    local marker="# lazy-cli PATH"
    local export_line="export PATH=\"\$HOME/bin:\$PATH\""
    local bashrc="${HOME}/.bashrc"

    # Make lazy available in the current shell
    case ":${PATH}:" in
        *":${bin_dir}:"*) ;;
        *) export PATH="${bin_dir}:${PATH}" ;;
    esac

    touch "$bashrc"

    if grep -qF "$marker" "$bashrc" 2>/dev/null; then
        return 0
    fi

    {
        echo ""
        echo "$marker"
        echo "$export_line"
    } >> "$bashrc"

    echo "Added \$HOME/bin to PATH in ~/.bashrc (restart Git Bash or: source ~/.bashrc)"
}

check_fzf() {
    if command -v fzf >/dev/null 2>&1; then
        return 0
    fi

    echo ""
    echo "Warning: fzf is not installed (required for: lazy branch.history)"
    echo "  Scoop:  scoop install fzf"
    echo "  Manual: https://github.com/junegunn/fzf/releases"
}

install_git_bash() {
    local install_dir="${HOME}/.lazy"
    local bin_dir="${HOME}/bin"
    local wrapper="${bin_dir}/lazy"

    echo "Detected Git Bash / MSYS environment."

    rm -rf "$install_dir"
    git clone "$REPO_URL" "$install_dir"

    chmod +x "$install_dir/lazy.sh"
    chmod +x "$install_dir/commands/"*.sh

    mkdir -p "$bin_dir"

    # Wrapper (not symlink): MSYS often cannot create native symlinks.
    cat > "$wrapper" <<EOF
#!/bin/bash
exec "${install_dir}/lazy.sh" "\$@"
EOF
    chmod +x "$wrapper"

    ensure_git_bash_path "$bin_dir"
    check_fzf

    echo "------------------------------------------"
    echo "Installation successful!"
    echo "Install dir: ${install_dir}"
    echo "Command:     ${wrapper}"
    echo ""
    echo "Run:"
    echo "  lazy branch.history"
    echo "  lazy kill <port>"
    echo "  lazy update"
}

if is_git_bash; then
    install_git_bash
elif is_macos; then
    install_macos
elif is_linux; then
    install_linux
else
    echo "Error: Unsupported operating system -> $(uname -s 2>/dev/null || echo unknown)" >&2
    exit 1
fi
