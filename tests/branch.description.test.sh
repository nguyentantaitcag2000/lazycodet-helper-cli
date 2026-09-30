#!/bin/bash
# Covers `lazy branch` (the colored list) and `lazy branch.description` (the
# flags and the fzf menu).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-branch-description-test.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-branch-description-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

OUT=""

fail() {
    echo "FAIL: $1" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$OUT" >&2
    exit 1
}

# fzf is replaced by a mock that answers from a queue: each call takes the next
# line of $QUEUE and prints the first input row containing it, or cancels like
# ESC when the queue is empty. Every list it was shown is appended to $SHOWN.
MOCK_BIN="$TEST_ROOT/mock-bin"
QUEUE="$TEST_ROOT/fzf-queue"
SHOWN="$TEST_ROOT/fzf-shown"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/fzf" <<'EOF'
#!/bin/sh
input=$(cat)
printf '%s\n--\n' "$input" >> "$LAZY_TEST_FZF_SHOWN"
pick=$(head -n 1 "$LAZY_TEST_FZF_QUEUE")
tail -n +2 "$LAZY_TEST_FZF_QUEUE" > "$LAZY_TEST_FZF_QUEUE.next"
mv "$LAZY_TEST_FZF_QUEUE.next" "$LAZY_TEST_FZF_QUEUE"
[ -n "$pick" ] || exit 130
printf '%s\n' "$input" | grep -F -- "$pick" | head -n 1
EOF
chmod +x "$MOCK_BIN/fzf"

# The editor mock writes $LAZY_TEST_EDITOR_TEXT over the template Git hands it.
cat > "$MOCK_BIN/mock-editor" <<'EOF'
#!/bin/sh
printf '%s\n' "$LAZY_TEST_EDITOR_TEXT" > "$1"
EOF
chmod +x "$MOCK_BIN/mock-editor"

REPO="$TEST_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Lazy Test"
git -C "$REPO" config user.email "lazy@example.com"
git -C "$REPO" commit -q --allow-empty -m "initial"
git -C "$REPO" branch feature/field-list
git -C "$REPO" branch fix/v1.2.hotfix
git -C "$REPO" branch chore/no-description
git -C "$REPO" config branch.main.description "Integration branch"
git -C "$REPO" config branch.feature/field-list.description $'Field list screen\nwith paging\n'
git -C "$REPO" config branch.fix/v1.2.hotfix.description "Dotted name"

lazy() {
    (
        cd "$REPO"
        PATH="$MOCK_BIN:$PATH" GIT_EDITOR="$MOCK_BIN/mock-editor" \
            LAZY_TEST_FZF_QUEUE="$QUEUE" LAZY_TEST_FZF_SHOWN="$SHOWN" \
            bash "$CLI" "$@"
    )
}

queue() {
    printf '%s\n' "$@" > "$QUEUE"
    : > "$SHOWN"
}

desc_of() {
    git -C "$REPO" config --get "branch.$1.description" || true
}

# ------------------------------------------------------------------ lazy branch

OUT=$(lazy branch --color=never </dev/null)
EXPECTED=$(cat <<'EOF'
  chore/no-description
  feature/field-list    Field list screen
                        with paging
  fix/v1.2.hotfix       Dotted name
● main                  Integration branch
EOF
)
[ "$OUT" = "$EXPECTED" ] || fail "the plain list is not aligned as expected"

OUT=$(lazy branch </dev/null)
case "$OUT" in
    *$'\033'*) fail "piped output is colored" ;;
esac
case "$OUT" in
    *"lazy branch.description"*) fail "the terminal hint leaked into piped output" ;;
esac

OUT=$(lazy branch --color=always </dev/null)
grep -qF $'\033[1;32mmain\033[0m' <<< "$OUT" ||
    fail "the current branch name is not colored as current"
grep -qF $'\033[1;36mfix/v1.2.hotfix\033[0m' <<< "$OUT" ||
    fail "a branch name is not colored"
grep -qF $'\033[33mDotted name\033[0m' <<< "$OUT" ||
    fail "a description is not colored differently from its name"

OUT=$(lazy branch --color=sometimes </dev/null 2>&1) &&
    fail "an invalid --color value was accepted"

echo "branch list tests passed"

# ------------------------------------------------------ branch.description flags

OUT=$(lazy branch.description --print </dev/null)
grep -q '^Branch       main (current)$' <<< "$OUT" || fail "--print does not default to the current branch"
grep -q '^Description  Integration branch$' <<< "$OUT" || fail "--print does not show the description"

OUT=$(lazy branch.description feature/field-list -p </dev/null)
grep -q '^             with paging$' <<< "$OUT" ||
    fail "a multi-line description is not aligned under its first line"

OUT=$(lazy branch.description chore/no-description -p </dev/null)
grep -q '^Description  (none)$' <<< "$OUT" || fail "a missing description is not reported"

lazy branch.description chore/no-description --set "  Tidy up  " </dev/null >/dev/null
[ "$(desc_of chore/no-description)" = "Tidy up" ] || fail "--set did not store the trimmed text"

OUT=$(lazy branch.description chore/no-description --set "   " </dev/null 2>&1) &&
    fail "--set accepted an empty description"

lazy branch.description chore/no-description --clear </dev/null >/dev/null
[ -z "$(desc_of chore/no-description)" ] || fail "--clear did not remove the description"

OUT=$(lazy branch.description chore/no-description --clear </dev/null)
grep -q 'has no description' <<< "$OUT" || fail "--clear on an empty description is not reported"

LAZY_TEST_EDITOR_TEXT="Written in the editor" lazy branch.description fix/v1.2.hotfix --edit </dev/null >/dev/null
[ "$(desc_of fix/v1.2.hotfix)" = "Written in the editor" ] || fail "--edit did not save what the editor wrote"

OUT=$(lazy branch.description missing/branch -p </dev/null 2>&1) && fail "an unknown branch was accepted"
grep -q 'Local branch not found -> missing/branch' <<< "$OUT" || fail "an unknown branch is not named in the error"

OUT=$(lazy branch.description --edit --clear </dev/null 2>&1) && fail "two actions were accepted together"

echo "branch.description flag tests passed"

# ------------------------------------------------------- branch.description menu

# ESC on the first menu leaves everything as it was.
queue
OUT=$(lazy branch.description </dev/null)
[ "$(desc_of main)" = "Integration branch" ] || fail "cancelling the menu changed the description"
grep -q 'Edit description' "$SHOWN" || fail "the menu has no edit action"
grep -q 'Clear description' "$SHOWN" || fail "the menu has no clear action for a described branch"
grep -q 'Choose another branch' "$SHOWN" || fail "the menu has no branch switch"

# Quick edit reads one line from stdin, then the menu comes back.
queue "Quick edit" "Quit"
OUT=$(printf 'Typed on one line\n' | lazy branch.description)
[ "$(desc_of main)" = "Typed on one line" ] || fail "quick edit did not save the typed line"
grep -q 'Description saved for main.' <<< "$OUT" || fail "quick edit did not report the change"
grep -q '^Description  Typed on one line$' <<< "$OUT" || fail "the menu did not redraw the new description"

# An empty quick edit keeps the description.
queue "Quick edit"
OUT=$(printf '\n' | lazy branch.description)
[ "$(desc_of main)" = "Typed on one line" ] || fail "an empty quick edit changed the description"

# Clear asks first; "n" keeps it and "y" removes it.
queue "Clear description"
printf 'n\n' | lazy branch.description >/dev/null
[ -n "$(desc_of main)" ] || fail "declining the clear prompt removed the description"
queue "Clear description"
printf 'y\n' | lazy branch.description >/dev/null
[ -z "$(desc_of main)" ] || fail "confirming the clear prompt kept the description"

# Without a description there is nothing to clear.
queue
lazy branch.description </dev/null >/dev/null
grep -q 'Clear description' "$SHOWN" && fail "clear is offered for a branch without a description"

# Switching branches in the menu retargets every later action.
queue "Choose another branch" "fix/v1.2.hotfix" "Edit description"
LAZY_TEST_EDITOR_TEXT="Edited after switching" lazy branch.description </dev/null >/dev/null
[ "$(desc_of fix/v1.2.hotfix)" = "Edited after switching" ] || fail "the switched branch was not edited"
[ -z "$(desc_of main)" ] || fail "an action after switching touched the first branch"
grep -qF 'feature/field-list' "$SHOWN" || fail "the branch picker did not list the branches"
grep -qF 'Field list screen …' "$SHOWN" ||
    fail "the branch picker does not shorten a multi-line description to its first line"

# A detached HEAD opens the branch picker instead of failing.
git -C "$REPO" checkout -q --detach
queue "feature/field-list"
OUT=$(lazy branch.description </dev/null)
grep -q '^Branch       feature/field-list$' <<< "$OUT" || fail "a detached HEAD did not fall back to the picker"
OUT=$(lazy branch.description --print </dev/null 2>&1) && fail "--print on a detached HEAD did not fail"
git -C "$REPO" checkout -q main

# Without fzf the description is still shown, with a way forward.
NO_FZF_BIN="$TEST_ROOT/no-fzf-bin"
mkdir -p "$NO_FZF_BIN"
for tool in git bash sh cat head tail mv grep dirname uname readlink tr sed awk cut; do
    ln -s "$(command -v "$tool")" "$NO_FZF_BIN/$tool"
done
OUT=$(cd "$REPO" && PATH="$NO_FZF_BIN" bash "$CLI" branch.description </dev/null)
grep -q 'Install fzf for the action menu' <<< "$OUT" || fail "a missing fzf is not explained"
grep -q '^Branch       main (current)$' <<< "$OUT" || fail "the description is hidden when fzf is missing"

echo "branch.description menu tests passed"
