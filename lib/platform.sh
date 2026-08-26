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

is_wsl() {
    # WSL1 and WSL2 both advertise Microsoft in the kernel string; the env var
    # is only set for interactive shells, so it is a hint, not the test.
    if [ -n "${WSL_DISTRO_NAME:-}" ]; then
        return 0
    fi

    if grep -qi microsoft /proc/version 2>/dev/null; then
        return 0
    fi

    return 1
}

# Absolute path to a Windows executable as seen from inside WSL. /mnt/c is
# case-insensitive, but the Windows directory itself is not always "Windows",
# so fall back to PATH (which interop populates) before guessing.
win_exe_path() {
    local name="$1"
    local found
    local candidate

    found="$(command -v "$name" 2>/dev/null)"
    if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
    fi

    for candidate in \
        "/mnt/c/Windows/System32/${name}" \
        "/mnt/c/WINDOWS/system32/${name}" \
        "/mnt/c/windows/system32/${name}"
    do
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

# Windows CLI switches start with "/". Git Bash rewrites that into a path, so
# it needs "//"; inside WSL nothing rewrites the argument and "/" is correct.
win_flag() {
    if is_git_bash; then
        printf '//%s' "$1"
    else
        printf '/%s' "$1"
    fi
}

# True when this WSL distro can execute Windows binaries. systemd-binfmt wipes
# the WSLInterop registration on some images, which silently breaks every
# .exe call with "Exec format error".
wsl_interop_ok() {
    local exe
    exe="$(win_exe_path cmd.exe)" || return 1
    # </dev/null on every Windows call: a .exe launched through interop drains
    # whatever stdin it inherits, which would swallow a piped confirmation.
    "$exe" /c exit >/dev/null 2>&1 </dev/null
}

# Re-register the stock WSL handler for this boot. Reverted by restarting the
# distro; wsl_interop_permanent_hint prints how to make it stick.
wsl_enable_interop() {
    local line=':WSLInterop:M::MZ::/init:PF'
    local reg=/proc/sys/fs/binfmt_misc/register

    [ -e "$reg" ] || return 1

    if [ "$(id -u)" = "0" ]; then
        printf '%s\n' "$line" > "$reg" 2>/dev/null || return 1
    elif command -v sudo >/dev/null 2>&1; then
        printf '%s\n' "$line" | sudo -n tee "$reg" >/dev/null 2>&1 || return 1
    else
        return 1
    fi

    wsl_interop_ok
}

wsl_interop_permanent_hint() {
    echo "  echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /usr/lib/binfmt.d/WSLInterop.conf"
}
