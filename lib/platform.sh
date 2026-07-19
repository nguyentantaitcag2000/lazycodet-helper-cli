#!/bin/bash
# Shared platform helpers for lazy CLI.
# Sourced by installed scripts; install.sh stays self-contained for curl|bash.

is_git_bash() {
    # Git for Windows (Git Bash), MSYS2, or Cygwin
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

git_bash_install_dir() {
    echo "${HOME}/.lazy"
}

git_bash_bin_dir() {
    echo "${HOME}/bin"
}
