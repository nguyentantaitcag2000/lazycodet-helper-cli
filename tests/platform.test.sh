#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-platform.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-platform.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

usage_output() {
    local status=0
    bash "$CLI" >"$TEST_ROOT/usage" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "usage should exit 1 without a command"
    cat "$TEST_ROOT/usage"
}

assert_has() {
    printf '%s\n' "$1" | grep -qF -- "$2" || fail "expected output to contain: $2"
}

assert_lacks() {
    if printf '%s\n' "$1" | grep -qF -- "$2"; then
        fail "expected output to omit: $2"
    fi
}

MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "${LAZY_TEST_UNAME:-Linux}"' > "$MOCK_BIN/uname"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$*" >> "$LAZY_TEST_SUDO_LOG"' > "$MOCK_BIN/sudo"
chmod +x "$MOCK_BIN/uname" "$MOCK_BIN/sudo"

simulated_usage() {
    LAZY_TEST_UNAME="$1" MSYSTEM= PATH="$MOCK_BIN:$PATH" bash "$CLI" 2>&1 || true
}

# The actual host validates its own registry view. macOS/Linux intentionally do
# not expose Windows-only commands; Git Bash does.
CURRENT_PLATFORM="$(bash -c 'source "$1"; platform_id' _ "${SCRIPT_DIR}/../lib/platform.sh")"
CURRENT_USAGE="$(usage_output)"
assert_has "$CURRENT_USAGE" "lazy agent.sync"
assert_has "$CURRENT_USAGE" "lazy git.commit"
assert_has "$CURRENT_USAGE" "lazy kill <port>"

case "$CURRENT_PLATFORM" in
    macos|linux|wsl)
        assert_lacks "$CURRENT_USAGE" "lazy claude.auth"
        assert_lacks "$CURRENT_USAGE" "lazy fix.font"
        ;;
    git-bash)
        assert_has "$CURRENT_USAGE" "lazy claude.auth"
        assert_has "$CURRENT_USAGE" "lazy fix.font"
        ;;
    *) fail "test is running on an unsupported platform: $CURRENT_PLATFORM" ;;
esac

# MSYSTEM is the primary Git Bash signal, so this simulation is portable on the
# Unix test hosts and exercises inclusion of Windows-only commands.
GIT_BASH_USAGE="$(MSYSTEM=MINGW64 bash "$CLI" 2>&1 || true)"
assert_has "$GIT_BASH_USAGE" "lazy claude.auth"
assert_has "$GIT_BASH_USAGE" "lazy fix.font"
assert_has "$GIT_BASH_USAGE" "lazy git.commit"

# Exercise both Unix registry views even when this test itself runs on only one
# of them. Git Bash has a readonly msys OSTYPE, so it validates its real branch
# above instead of pretending to be Unix.
if [ "$CURRENT_PLATFORM" != "git-bash" ]; then
    for simulated_platform in Darwin Linux; do
        SIMULATED_USAGE="$(simulated_usage "$simulated_platform")"
        assert_has "$SIMULATED_USAGE" "lazy agent.sync"
        assert_has "$SIMULATED_USAGE" "lazy git.commit"
        assert_lacks "$SIMULATED_USAGE" "lazy claude.auth"
        assert_lacks "$SIMULATED_USAGE" "lazy fix.font"
    done

    WSL_USAGE="$(LAZY_TEST_UNAME=Linux WSL_DISTRO_NAME=Ubuntu MSYSTEM= \
        PATH="$MOCK_BIN:$PATH" bash "$CLI" 2>&1 || true)"
    assert_lacks "$WSL_USAGE" "lazy claude.auth"
    assert_lacks "$WSL_USAGE" "lazy fix.font"
fi

if [ "$CURRENT_PLATFORM" = "macos" ] || [ "$CURRENT_PLATFORM" = "linux" ]; then
    if bash "$CLI" claude.auth --help >"$TEST_ROOT/rejected" 2>&1; then
        fail "Windows-only command was dispatched on $CURRENT_PLATFORM"
    fi
    grep -qF "is not available" "$TEST_ROOT/rejected" ||
        fail "platform rejection did not explain command availability"

    LOCAL_KILL_HELP="$(bash "$CLI" kill --help)"
    assert_lacks "$LOCAL_KILL_HELP" "--wsl"
    assert_lacks "$LOCAL_KILL_HELP" "--host"

    if bash "$CLI" kill 12345 --wsl >"$TEST_ROOT/kill-rejected" 2>&1; then
        fail "WSL-only kill option was accepted on $CURRENT_PLATFORM"
    fi
    grep -qF "only available on WSL or Git Bash" "$TEST_ROOT/kill-rejected" ||
        fail "kill option rejection did not explain platform availability"
fi

GIT_BASH_KILL_HELP="$(MSYSTEM=MINGW64 bash "$CLI" kill --help)"
assert_has "$GIT_BASH_KILL_HELP" "--wsl"
assert_has "$GIT_BASH_KILL_HELP" "--host"

if [ "$CURRENT_PLATFORM" != "git-bash" ]; then
    WSL_KILL_HELP="$(LAZY_TEST_UNAME=Linux WSL_DISTRO_NAME=Ubuntu MSYSTEM= \
        PATH="$MOCK_BIN:$PATH" bash "$CLI" kill --help)"
    assert_has "$WSL_KILL_HELP" "--wsl"
    assert_has "$WSL_KILL_HELP" "--host"

    # The installer must select a dedicated macOS path rather than falling through
    # to Linux. sudo is mocked so this checks routing without touching /usr/local.
    SUDO_LOG="$TEST_ROOT/sudo.log"
    INSTALL_OUTPUT="$({
        LAZY_TEST_UNAME=Darwin LAZY_TEST_SUDO_LOG="$SUDO_LOG" MSYSTEM= \
            PATH="$MOCK_BIN:$PATH" bash "${SCRIPT_DIR}/../install.sh"
    } 2>&1)"
    assert_has "$INSTALL_OUTPUT" "Detected macOS."
    grep -qF "/usr/local/lib/lazy" "$SUDO_LOG" ||
        fail "macOS installer did not use /usr/local/lib/lazy"
    if grep -qF "/opt/lazy" "$SUDO_LOG"; then
        fail "macOS installer fell through to the Linux install path"
    fi
fi

# The launcher must work through a relative symlink without GNU readlink -f.
ln -s "$CLI" "$TEST_ROOT/lazy"
SYMLINK_USAGE="$(cd "$TEST_ROOT" && bash ./lazy 2>&1 || true)"
assert_has "$SYMLINK_USAGE" "lazy agent.sync"

echo "platform tests passed ($CURRENT_PLATFORM)"
