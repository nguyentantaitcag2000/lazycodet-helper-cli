#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-branch-history-test.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-branch-history-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    echo "--- list ---" >&2
    printf '%s\n' "${LIST:-}" >&2
    exit 1
}

# The picker is replaced by a mock that prints the list it was given on stderr
# and cancels, so the list can be asserted without checking anything out.
MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
printf '%s\n' \
    '#!/bin/sh' \
    'cat >&2' \
    'exit 130' > "$MOCK_BIN/fzf"
chmod +x "$MOCK_BIN/fzf"

REPO="$TEST_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Lazy Test"
git -C "$REPO" config user.email "lazy@example.com"

# Every ref update and reflog entry gets an explicit date so ordering is
# deterministic instead of depending on how fast the test runs.
at() {
    local when="$1"
    shift
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$REPO" "$@"
}

at "2026-01-01T09:00:00" commit -q --allow-empty -m "initial"

at "2026-01-02T09:00:00" checkout -q -b feature/field-list
at "2026-01-02T10:00:00" commit -q --allow-empty -m "field list"
at "2026-01-02T11:00:00" branch -m feature/FAE-CSOL.202609.014-field-list

at "2026-01-03T09:00:00" checkout -q main
at "2026-01-04T09:00:00" checkout -q -b fix/session-expiry
at "2026-01-05T09:00:00" checkout -q main
at "2026-01-05T10:00:00" branch -q -D fix/session-expiry

# Never checked out under this name, so it only exists as a ref.
at "2026-01-06T09:00:00" branch -q chore/untouched

# A detached checkout puts a raw commit id in the reflog.
at "2026-01-07T09:00:00" checkout -q --detach HEAD
at "2026-01-07T10:00:00" checkout -q main

run_list() {
    LIST=$(
        cd "$REPO"
        PATH="$MOCK_BIN:$PATH" bash "$CLI" branch.history </dev/null 2>&1 >/dev/null
    )
}

run_list

grep -q '○ feature/FAE-CSOL.202609.014-field-list ' <<< "$LIST" ||
    fail "a renamed branch is missing under its current name"
grep -q 'feature/field-list |' <<< "$LIST" &&
    fail "a renamed branch is still listed under its old name"
grep -q 'fix/session-expiry' <<< "$LIST" &&
    fail "a deleted branch is still listed"
grep -q '● main ' <<< "$LIST" ||
    fail "the current branch is not marked"
grep -q '○ chore/untouched ' <<< "$LIST" ||
    fail "a branch that was never checked out is missing"
grep -qE '^[^ ]+ [^ ]+ +\| [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' <<< "$LIST" ||
    fail "rows do not end in a checkout date"
[ "$(grep -c . <<< "$LIST")" -eq 3 ] ||
    fail "expected exactly the three branches that exist"

# The rename keeps the date of the checkout it inherits, not the rename or the
# last commit, so recency still reflects when the branch was last visited.
grep -q 'feature/FAE-CSOL.202609.014-field-list | 2026-01-02 09:00:00' <<< "$LIST" ||
    fail "a renamed branch lost the date of its original checkout"

[ "$(sed -n 1p <<< "$LIST" | awk '{print $2}')" = "main" ] ||
    fail "the most recent checkout is not first"

# Selecting a row must check that branch out, including a renamed one.
printf '%s\n' \
    '#!/bin/sh' \
    'grep -F -- "${LAZY_TEST_FZF_MATCH:?}"' > "$MOCK_BIN/fzf"
(
    cd "$REPO"
    LAZY_TEST_FZF_MATCH='feature/FAE-CSOL.202609.014-field-list' \
        PATH="$MOCK_BIN:$PATH" bash "$CLI" branch.history </dev/null >/dev/null 2>&1
)
[ "$(git -C "$REPO" branch --show-current)" = "feature/FAE-CSOL.202609.014-field-list" ] ||
    fail "selecting a renamed branch did not check it out"

echo "branch.history tests passed"

# A chain of renames must collapse to the final name, and a new branch that
# reuses a freed name must stay a separate entry with its own date.
CHAIN_REPO="$TEST_ROOT/chain"
mkdir -p "$CHAIN_REPO"
git -C "$CHAIN_REPO" init -q -b main
git -C "$CHAIN_REPO" config user.name "Lazy Test"
git -C "$CHAIN_REPO" config user.email "lazy@example.com"

chain_at() {
    local when="$1"
    shift
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$CHAIN_REPO" "$@"
}

chain_at "2026-02-01T09:00:00" commit -q --allow-empty -m "initial"
chain_at "2026-02-02T09:00:00" checkout -q -b draft
chain_at "2026-02-02T10:00:00" branch -m wip/one
chain_at "2026-02-02T11:00:00" branch -m feature/final
chain_at "2026-02-03T09:00:00" checkout -q main
chain_at "2026-02-04T09:00:00" checkout -q -b draft
chain_at "2026-02-05T09:00:00" checkout -q main

printf '%s\n' \
    '#!/bin/sh' \
    'cat >&2' \
    'exit 130' > "$MOCK_BIN/fzf"
LIST=$(
    cd "$CHAIN_REPO"
    PATH="$MOCK_BIN:$PATH" bash "$CLI" branch.history </dev/null 2>&1 >/dev/null
)

grep -q 'feature/final | 2026-02-02 09:00:00' <<< "$LIST" ||
    fail "a chain of renames did not collapse to the final name"
grep -q "wip/one" <<< "$LIST" &&
    fail "an intermediate rename is listed"
grep -q '○ draft  *| 2026-02-04 09:00:00' <<< "$LIST" ||
    fail "a new branch reusing a freed name did not get its own entry"
[ "$(grep -c . <<< "$LIST")" -eq 3 ] ||
    fail "expected exactly main, draft and feature/final"

echo "branch.history rename-chain tests passed"
