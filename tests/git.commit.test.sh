#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-git-commit-test.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-git-commit-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${LAZY_TEST_FZF_CANCEL:-0}" = 1 ]; then exit 130; fi' \
    'grep -E -- "${LAZY_TEST_FZF_MATCH:?}"' > "$MOCK_BIN/fzf"
chmod +x "$MOCK_BIN/fzf"

new_repo() {
    local repo="$1"

    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Lazy Test"
    git -C "$repo" config user.email "lazy@example.com"
    printf 'base selected\n' > "$repo/selected.txt"
    printf 'base staged\n' > "$repo/staged-only.txt"
    printf 'base mixed\n' > "$repo/mixed.txt"
    printf 'base delete\n' > "$repo/delete-me.txt"
    printf 'base rename\n' > "$repo/rename-old.txt"
    git -C "$repo" add .
    git -C "$repo" commit -qm "initial"
}

REPO="$TEST_ROOT/repo with spaces"
new_repo "$REPO"

printf 'selected now\n' > "$REPO/selected.txt"
printf 'staged and preserved\n' > "$REPO/staged-only.txt"
git -C "$REPO" add staged-only.txt
printf 'unstaged and preserved\n' >> "$REPO/staged-only.txt"
printf 'mixed staged snapshot\n' > "$REPO/mixed.txt"
git -C "$REPO" add mixed.txt
printf 'mixed final snapshot\n' > "$REPO/mixed.txt"
printf 'brand new\n' > "$REPO/new file.txt"
rm "$REPO/delete-me.txt"
git -C "$REPO" mv rename-old.txt rename-new.txt

STAGED_BEFORE=$(git -C "$REPO" diff --cached --binary -- staged-only.txt)
UNSTAGED_BEFORE=$(git -C "$REPO" diff --binary -- staged-only.txt)

(
    cd "$REPO"
    printf 'commit picked files\n' | LAZY_TEST_FZF_MATCH='selected.txt|mixed.txt|new file.txt|delete-me.txt|rename-' \
        PATH="$MOCK_BIN:$PATH" bash "$CLI" git.commit >/dev/null
)

[ "$(git -C "$REPO" show HEAD:selected.txt)" = "selected now" ] ||
    fail "tracked working-tree content was not committed"
[ "$(git -C "$REPO" show HEAD:mixed.txt)" = "mixed final snapshot" ] ||
    fail "the final content of a partially staged file was not committed"
[ "$(git -C "$REPO" show 'HEAD:new file.txt')" = "brand new" ] ||
    fail "untracked file was not committed"
if git -C "$REPO" cat-file -e HEAD:delete-me.txt 2>/dev/null; then
    fail "selected deletion was not committed"
fi
[ "$(git -C "$REPO" show HEAD:rename-new.txt)" = "base rename" ] ||
    fail "selected rename was not committed"
if git -C "$REPO" cat-file -e HEAD:rename-old.txt 2>/dev/null; then
    fail "the old side of a selected rename was not removed"
fi
[ -z "$(git -C "$REPO" status --short -- selected.txt mixed.txt 'new file.txt' delete-me.txt rename-old.txt rename-new.txt)" ] ||
    fail "selected files were not clean after the commit"
[ "$(git -C "$REPO" diff --cached --binary -- staged-only.txt)" = "$STAGED_BEFORE" ] ||
    fail "unselected staged content changed"
[ "$(git -C "$REPO" diff --binary -- staged-only.txt)" = "$UNSTAGED_BEFORE" ] ||
    fail "unselected unstaged content changed"

CANCEL_REPO="$TEST_ROOT/cancel"
new_repo "$CANCEL_REPO"
printf 'changed\n' > "$CANCEL_REPO/selected.txt"
CANCEL_HEAD=$(git -C "$CANCEL_REPO" rev-parse HEAD)
(
    cd "$CANCEL_REPO"
    LAZY_TEST_FZF_CANCEL=1 LAZY_TEST_FZF_MATCH='.' PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" git.commit >/dev/null
)
[ "$(git -C "$CANCEL_REPO" rev-parse HEAD)" = "$CANCEL_HEAD" ] ||
    fail "cancelling created a commit"
[ "$(git -C "$CANCEL_REPO" status --short)" = ' M selected.txt' ] ||
    fail "cancelling changed the working state"

FAIL_REPO="$TEST_ROOT/hook failure"
new_repo "$FAIL_REPO"
printf 'changed\n' > "$FAIL_REPO/selected.txt"
printf 'keep staged\n' > "$FAIL_REPO/staged-only.txt"
git -C "$FAIL_REPO" add staged-only.txt
FAIL_HEAD=$(git -C "$FAIL_REPO" rev-parse HEAD)
FAIL_STAGED=$(git -C "$FAIL_REPO" diff --cached --binary)
printf '%s\n' '#!/bin/sh' 'exit 1' > "$FAIL_REPO/.git/hooks/pre-commit"
chmod +x "$FAIL_REPO/.git/hooks/pre-commit"

if (
    cd "$FAIL_REPO"
    printf 'must fail\n' | LAZY_TEST_FZF_MATCH='selected.txt' PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" git.commit >/dev/null 2>&1
); then
    fail "a rejected pre-commit hook reported success"
fi
[ "$(git -C "$FAIL_REPO" rev-parse HEAD)" = "$FAIL_HEAD" ] ||
    fail "hook failure moved HEAD"
[ "$(git -C "$FAIL_REPO" diff --cached --binary)" = "$FAIL_STAGED" ] ||
    fail "hook failure changed the real staging area"

UNBORN_REPO="$TEST_ROOT/unborn"
mkdir -p "$UNBORN_REPO"
git -C "$UNBORN_REPO" init -q
git -C "$UNBORN_REPO" config user.name "Lazy Test"
git -C "$UNBORN_REPO" config user.email "lazy@example.com"
printf 'first file\n' > "$UNBORN_REPO/first.txt"
printf 'keep staged\n' > "$UNBORN_REPO/keep.txt"
git -C "$UNBORN_REPO" add keep.txt
(
    cd "$UNBORN_REPO"
    printf 'first selected commit\n' | LAZY_TEST_FZF_MATCH='first.txt' PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" git.commit >/dev/null
)
[ "$(git -C "$UNBORN_REPO" show HEAD:first.txt)" = "first file" ] ||
    fail "untracked file was not committed in an unborn repository"
[ "$(git -C "$UNBORN_REPO" status --short -- keep.txt)" = 'A  keep.txt' ] ||
    fail "unselected staged file changed in an unborn repository"

echo "git.commit tests passed"
