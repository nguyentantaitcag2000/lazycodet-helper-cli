#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

# Sync an install checkout to the matching origin branch, discarding local edits.
# Install dirs are not working copies — manual tweaks must not block updates.
sync_install_repo() {
    local install_dir="$1"
    local use_sudo="${2:-0}"
    local branch
    local target

    if [ "$use_sudo" -eq 1 ]; then
        sudo git -C "$install_dir" fetch --prune origin
        branch="$(sudo git -C "$install_dir" rev-parse --abbrev-ref HEAD)"
        if [ "$branch" = "HEAD" ]; then
            target="origin/main"
        else
            target="origin/${branch}"
        fi
        sudo git -C "$install_dir" reset --hard "$target"
        sudo git -C "$install_dir" clean -fd
    else
        git -C "$install_dir" fetch --prune origin
        branch="$(git -C "$install_dir" rev-parse --abbrev-ref HEAD)"
        if [ "$branch" = "HEAD" ]; then
            target="origin/main"
        else
            target="origin/${branch}"
        fi
        git -C "$install_dir" reset --hard "$target"
        git -C "$install_dir" clean -fd
    fi
}

update_linux() {
    local install_dir="/opt/lazy"

    echo "Checking for updates..."

    if [ ! -d "${install_dir}/.git" ]; then
        echo "Error: Install not found at ${install_dir}"
        echo "Re-run install.sh first."
        exit 1
    fi

    sync_install_repo "$install_dir" 1

    sudo chmod +x "$install_dir/lazy.sh"
    sudo chmod +x "$install_dir/commands/"*.sh
    sudo ln -sf "$install_dir/lazy.sh" /usr/local/bin/lazy

    echo "Successfully updated!"
}

refresh_git_bash_wrapper() {
    local install_dir="$1"
    local bin_dir
    bin_dir="$(git_bash_bin_dir)"
    local wrapper="${bin_dir}/lazy"

    mkdir -p "$bin_dir"
    cat > "$wrapper" <<EOF
#!/bin/bash
exec "${install_dir}/lazy.sh" "\$@"
EOF
    chmod +x "$wrapper"
}

update_git_bash() {
    local install_dir
    install_dir="$(git_bash_install_dir)"

    echo "Checking for updates (Git Bash)..."

    if [ ! -d "${install_dir}/.git" ]; then
        echo "Error: Install not found at ${install_dir}"
        echo "Re-run install.sh first."
        exit 1
    fi

    sync_install_repo "$install_dir" 0

    chmod +x "$install_dir/lazy.sh"
    chmod +x "$install_dir/commands/"*.sh
    refresh_git_bash_wrapper "$install_dir"

    echo "Successfully updated!"
}

if is_git_bash; then
    update_git_bash
else
    update_linux
fi
