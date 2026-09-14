#!/bin/bash
# Pick changed files and commit their current contents without disturbing the
# staged state of files that were not selected.

set -u

usage() {
    echo "Usage:"
    echo "  lazy git.commit"
    echo ""
    echo "Pick changed files with fzf, then enter a commit message."
    echo "Only the selected files are committed; unselected staged files stay staged."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "Error: Unexpected argument -> $1" >&2; echo ""; usage; exit 1 ;;
    esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: This directory is not a Git repository." >&2
    exit 1
fi

if ! command -v fzf >/dev/null 2>&1; then
    echo "Error: fzf is not installed." >&2
    echo "       Install it, then run 'lazy git.commit' again." >&2
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
cd "$REPO_ROOT" || exit 1

git_path_exists() {
    local path
    path=$(git rev-parse --git-path "$1" 2>/dev/null) || return 1
    [ -e "$path" ]
}

if git_path_exists MERGE_HEAD || git_path_exists CHERRY_PICK_HEAD ||
    git_path_exists REVERT_HEAD || git_path_exists rebase-merge ||
    git_path_exists rebase-apply; then
    echo "Error: A merge, rebase, cherry-pick, or revert is in progress." >&2
    echo "       Finish or abort it with Git before using 'lazy git.commit'." >&2
    exit 1
fi

if [ -n "$(git ls-files --unmerged)" ]; then
    echo "Error: This repository has unresolved conflicts." >&2
    echo "       Resolve them with Git before using 'lazy git.commit'." >&2
    exit 1
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lazy-git-commit.XXXXXX" 2>/dev/null)
if [ -z "$TEMP_DIR" ] || [ ! -d "$TEMP_DIR" ]; then
    echo "Error: Could not create a temporary directory." >&2
    exit 1
fi

cleanup() {
    case "$TEMP_DIR" in
        "${TMPDIR:-/tmp}"/lazy-git-commit.*) rm -rf -- "$TEMP_DIR" ;;
        *) echo "Warning: Refusing to remove unexpected temporary path: $TEMP_DIR" >&2 ;;
    esac
}
trap cleanup EXIT

CHOICES_FILE="$TEMP_DIR/choices"
TEMP_INDEX="$TEMP_DIR/index"
PATHS=()
SOURCE_PATHS=()

sanitize_display_path() {
    local value="$1"
    value=${value//$'\t'/\\t}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    printf '%s' "$value"
}

format_status() {
    local status="$1"
    local index_status=${status:0:1}
    local worktree_status=${status:1:1}

    if [ "$status" = "??" ]; then
        display_change="?"
        display_state="untracked"
    elif [ "$index_status" != " " ] && [ "$worktree_status" != " " ]; then
        if [ "$index_status" = "$worktree_status" ]; then
            display_change="$index_status"
        else
            display_change="${index_status}/${worktree_status}"
        fi
        display_state="staged + unstaged"
    elif [ "$index_status" != " " ]; then
        display_change="$index_status"
        display_state="staged"
    else
        display_change="$worktree_status"
        display_state="unstaged"
    fi
}

while IFS= read -r -d '' record; do
    status=${record:0:2}
    path=${record:3}
    source_path=""

    case "$status" in
        *R*|*C*)
            IFS= read -r -d '' source_path || true
            display_path="$(sanitize_display_path "$source_path") -> $(sanitize_display_path "$path")"
            ;;
        *) display_path=$(sanitize_display_path "$path") ;;
    esac

    format_status "$status"
    PATHS+=("$path")
    SOURCE_PATHS+=("$source_path")
    printf '%s\t%-3s %-19s %s\n' \
        "${#PATHS[@]}" "$display_change" "$display_state" "$display_path" >> "$CHOICES_FILE"
done < <(git -c core.quotePath=false status --porcelain=v1 -z --untracked-files=all)

if [ "${#PATHS[@]}" -eq 0 ]; then
    echo "Info: Nothing to commit."
    exit 0
fi

SELECTED_OUTPUT=$(fzf \
    --multi \
    --height=80% \
    --layout=reverse \
    --border \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --bind='space:toggle+down' \
    --marker='*' \
    --prompt='Commit files > ' \
    --header=$'CHG STATE               FILE\nSPACE = select/unselect | ENTER = continue | ESC = cancel' \
    < "$CHOICES_FILE")
FZF_STATUS=$?

case "$FZF_STATUS" in
    0)
        if [ -z "$SELECTED_OUTPUT" ]; then
            echo "Cancelled."
            exit 0
        fi
        ;;
    1|130)
        echo "Cancelled."
        exit 0
        ;;
    *)
        echo "Error: fzf could not open the file picker." >&2
        exit "$FZF_STATUS"
        ;;
esac

SELECTED_PATHSPECS=()
while IFS=$'\t' read -r selected_id _; do
    case "$selected_id" in
        ''|*[!0-9]*)
            echo "Error: Could not read the selected files from fzf." >&2
            exit 1
            ;;
    esac

    selected_index=$((selected_id - 1))
    selected_path=${PATHS[$selected_index]}
    selected_source=${SOURCE_PATHS[$selected_index]}

    SELECTED_PATHSPECS+=(":(top,literal)$selected_path")
    if [ -n "$selected_source" ]; then
        SELECTED_PATHSPECS+=(":(top,literal)$selected_source")
    fi
done <<< "$SELECTED_OUTPUT"

echo ""
printf 'Commit message: '
if ! IFS= read -r COMMIT_MESSAGE; then
    echo ""
    echo "Cancelled."
    exit 0
fi

if [ -z "$(printf '%s' "$COMMIT_MESSAGE" | tr -d '[:space:]')" ]; then
    echo "Error: Commit message must not be empty." >&2
    exit 1
fi

OLD_HEAD=$(git rev-parse --verify HEAD 2>/dev/null || true)
if [ -n "$OLD_HEAD" ]; then
    GIT_INDEX_FILE="$TEMP_INDEX" git read-tree "$OLD_HEAD" || exit 1
else
    GIT_INDEX_FILE="$TEMP_INDEX" git read-tree --empty || exit 1
fi

if ! GIT_INDEX_FILE="$TEMP_INDEX" git add -A -- "${SELECTED_PATHSPECS[@]}"; then
    echo "Error: Could not prepare the selected files. The real staging area was not changed." >&2
    exit 1
fi

if GIT_INDEX_FILE="$TEMP_INDEX" git diff --cached --quiet --exit-code; then
    echo "Info: The selected files have no current changes to commit."
    echo "      The real staging area was not changed."
    exit 0
fi

GIT_INDEX_FILE="$TEMP_INDEX" git commit -m "$COMMIT_MESSAGE"
COMMIT_STATUS=$?
NEW_HEAD=$(git rev-parse --verify HEAD 2>/dev/null || true)

if [ -n "$NEW_HEAD" ] && [ "$NEW_HEAD" != "$OLD_HEAD" ]; then
    if ! git reset --quiet "$NEW_HEAD" -- "${SELECTED_PATHSPECS[@]}"; then
        echo "Error: The commit was created, but the selected files could not be refreshed" >&2
        echo "       in the real staging area. Run: git reset HEAD -- <selected-files>" >&2
        exit 1
    fi
fi

if [ "$COMMIT_STATUS" -ne 0 ] && [ "$NEW_HEAD" = "$OLD_HEAD" ]; then
    echo "Error: Git did not create the commit. The real staging area was not changed." >&2
    exit "$COMMIT_STATUS"
fi

if [ "$COMMIT_STATUS" -ne 0 ]; then
    echo "Warning: Git created the commit, but a hook reported an error afterwards." >&2
    exit "$COMMIT_STATUS"
fi
