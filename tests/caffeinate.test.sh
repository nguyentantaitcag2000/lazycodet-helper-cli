#!/bin/bash
#
# The parsing is the fragile half of `lazy caffeinate`, and it cannot be
# exercised by starting real caffeinate processes: the interesting cases are a
# six-hour-old assertion, a process owned by somebody else, and pmset output
# with another owner's timeout sitting between two caffeinate blocks. So the
# command reads recorded ps/pmset output through LAZY_TEST_PS_FILE and
# LAZY_TEST_PMSET_FILE, which also lets this run on the Linux CI host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
CMD="${SCRIPT_DIR}/../commands/caffeinate.sh"
PMSET_FIXTURE="${SCRIPT_DIR}/fixtures/caffeinate.pmset.txt"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-caffeinate.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-caffeinate.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_has() {
    printf '%s\n' "$1" | grep -qF -- "$2" || fail "expected output to contain: $2"
}

assert_lacks() {
    if printf '%s\n' "$1" | grep -qF -- "$2"; then
        fail "expected output to omit: $2"
    fi
}

# ps prints lstart as "Thu Sep 10 18:52:06 2026". Rows meant to read as "today"
# have to be generated, or the test would only pass on the day it was written.
TODAY="$(date '+%a %b %e %T %Y')"
PS_FIXTURE="$TEST_ROOT/ps.txt"
cat > "$PS_FIXTURE" <<PS_END
    1     0 root     $TODAY 1-06:20:00 launchd    /sbin/launchd
41649 65739 $(id -un) $TODAY 06:17:14 zsh        /bin/zsh -c source /home/x/.claude/shell-snapshots/snap.sh && eval 'caffeinate -dimsu -t 21600'
41651 41649 $(id -un) $TODAY 06:17:14 caffeinate caffeinate -dimsu -t 21600
73350     1 $(id -un) $TODAY 00:04:11 caffeinate caffeinate -i -t 300
73550 73548 $(id -un) Wed Sep  9 22:10:44 2020 1-20:45:33 caffeinate caffeinate -i sleep 600
73548     1 $(id -un) Wed Sep  9 22:10:44 2020 1-20:45:33 sleep      sleep 600
99001 65739 nobodyelse $TODAY 01:00:00 caffeinate caffeinate
PS_END

run_list() {
    LAZY_TEST_PS_FILE="$PS_FIXTURE" \
    LAZY_TEST_PMSET_FILE="$PMSET_FIXTURE" \
    NO_COLOR=1 COLUMNS=200 bash "$CMD" "$@" 2>&1
}

LIST="$(run_list --list)"

# A pid can legitimately appear in a note ("started by 41649") without being a
# row of its own, so the listing checks anchor on the numbered row itself.
assert_row() {
    printf '%s\n' "$LIST" | grep -qE "^  [0-9]+ +$1 " || fail "$1 was not listed as a row"
}

assert_not_row() {
    if printf '%s\n' "$LIST" | grep -qE "^  [0-9]+ +$1 "; then
        fail "$1 was listed as a caffeinate row"
    fi
}

# --- what is and is not a caffeinate process -------------------------------

# The whole point of matching on comm: this shell only *mentions* caffeinate in
# its -c string, which is exactly what `pgrep -f caffeinate` reports as a hit.
assert_not_row 41649
# The wrapped command is not a caffeinate process either.
assert_not_row 73548
assert_has "$LIST" "4 caffeinate processes are keeping this Mac awake."

for pid in 41651 73350 73550 99001; do
    assert_row "$pid"
done

# --- remaining time --------------------------------------------------------

# 21600s declared, 6120s left. The regression guarded here is pmset's
# "Timeout will fire in 120 secs" for WindowServer, which sits between the two
# caffeinate blocks in the fixture: charging it to the previous owner would
# report roughly two minutes left instead of one hour forty-two.
assert_has "$LIST" "1h 42m"
assert_lacks "$LIST" "2m 0s"
# 289s left on a 300s timeout.
assert_has "$LIST" "4m 49s"
# Wrapping a command, so nothing bounds it but the command itself.
assert_has "$LIST" "until it ends"
# No -t and nothing wrapped: unbounded until someone stops it.
assert_has "$LIST" "no timeout"

# --- what each one holds ---------------------------------------------------

assert_has "$LIST" "DIMSU"      # -dimsu asserts all five
assert_has "$LIST" ".I..."      # -i asserts idle system sleep only
assert_has "$LIST" "-----"      # running, but holding no assertion at all

# --- the notes under each row ----------------------------------------------

assert_has "$LIST" "wrapping 'sleep' (pid 73548)"
assert_has "$LIST" "orphaned"
assert_has "$LIST" "owned by nobodyelse"
assert_has "$LIST" "started by 41649"
# Today's rows are stamped as today; the 2020 row keeps its date.
assert_has "$LIST" "today "
assert_has "$LIST" "Sep 09 22:10"

# --- durations -------------------------------------------------------------

assert_has "$LIST" "6h 17m"     # 06:17:14
assert_has "$LIST" "1d 20h"     # 1-20:45:33
assert_has "$LIST" "4m 11s"     # 00:04:11

# --- refusals --------------------------------------------------------------

if run_list --kill 1 -y >/dev/null 2>&1; then
    fail "--kill accepted a pid that is not a listed caffeinate"
fi
assert_has "$(run_list --kill 1 -y || true)" "not a caffeinate process"

if run_list --kill 73548 -y >/dev/null 2>&1; then
    fail "--kill accepted the wrapped command instead of the caffeinate"
fi

if run_list --kill abc >/dev/null 2>&1; then
    fail "--kill accepted a non-numeric pid"
fi

if run_list --bogus >/dev/null 2>&1; then
    fail "an unknown option was accepted"
fi

if run_list extra >/dev/null 2>&1; then
    fail "a stray positional argument was accepted"
fi

# --- empty state -----------------------------------------------------------

: > "$TEST_ROOT/empty"
EMPTY="$(LAZY_TEST_PS_FILE="$TEST_ROOT/empty" LAZY_TEST_PMSET_FILE="$TEST_ROOT/empty" \
    NO_COLOR=1 bash "$CMD" --list 2>&1)"
assert_has "$EMPTY" "Nothing is holding this Mac awake."

# --- platform gating -------------------------------------------------------

CURRENT_PLATFORM="$(bash -c 'source "$1"; platform_id' _ "${SCRIPT_DIR}/../lib/platform.sh")"
USAGE="$(bash "$CLI" 2>&1 || true)"

case "$CURRENT_PLATFORM" in
    macos)
        assert_has "$USAGE" "lazy caffeinate"
        ;;
    *)
        assert_lacks "$USAGE" "lazy caffeinate"
        if bash "$CLI" caffeinate --list >/dev/null 2>&1; then
            fail "macOS-only command was dispatched on $CURRENT_PLATFORM"
        fi
        # Reached directly, with no fixtures, it must refuse rather than run
        # ps and pmset flags that do not exist here.
        if bash "$CMD" --list >/dev/null 2>&1; then
            fail "caffeinate.sh ran on $CURRENT_PLATFORM without fixtures"
        fi
        assert_has "$(bash "$CMD" --list 2>&1 || true)" "only available on macOS"
        ;;
esac

# Both registry views are checked wherever this runs, so a Linux CI host still
# catches a macOS-only command leaking onto the other platforms. Git Bash has a
# readonly msys OSTYPE, so it validates its real branch above instead.
if [ "$CURRENT_PLATFORM" != "git-bash" ]; then
    MOCK_BIN="$TEST_ROOT/mock-bin"
    mkdir -p "$MOCK_BIN"
    printf '%s\n' \
        '#!/bin/sh' \
        'printf "%s\n" "${LAZY_TEST_UNAME:-Linux}"' > "$MOCK_BIN/uname"
    chmod +x "$MOCK_BIN/uname"

    MAC_USAGE="$(LAZY_TEST_UNAME=Darwin MSYSTEM='' PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" 2>&1 || true)"
    assert_has "$MAC_USAGE" "lazy caffeinate"

    LINUX_USAGE="$(LAZY_TEST_UNAME=Linux MSYSTEM='' PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" 2>&1 || true)"
    assert_lacks "$LINUX_USAGE" "lazy caffeinate"
fi

GIT_BASH_USAGE="$(MSYSTEM=MINGW64 bash "$CLI" 2>&1 || true)"
assert_lacks "$GIT_BASH_USAGE" "lazy caffeinate"

echo "caffeinate tests passed ($CURRENT_PLATFORM)"
