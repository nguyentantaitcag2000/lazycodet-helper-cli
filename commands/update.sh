#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LAZY_UPDATE_LIB_DIR:-${SCRIPT_DIR}/../lib}"

# The update rewrites this file in place (git reset --hard). Bash parses scripts
# lazily, so a script still being read from the install dir would resume at a
# stale byte offset and report a bogus syntax error after a successful update.
# Run the real work from a throwaway copy that git cannot touch.
if [ -z "${LAZY_UPDATE_REEXEC:-}" ]; then
    self_copy="$(mktemp "${TMPDIR:-/tmp}/lazy-update.XXXXXX")"
    cp "${BASH_SOURCE[0]}" "$self_copy"

    status=0
    LAZY_UPDATE_REEXEC=1 LAZY_UPDATE_LIB_DIR="$LIB_DIR" \
        bash "$self_copy" "$@" || status=$?

    rm -f "$self_copy"
    exit "$status"
fi

# shellcheck source=../lib/platform.sh
source "${LIB_DIR}/platform.sh"

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
