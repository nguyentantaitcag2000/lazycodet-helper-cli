#!/bin/bash
# Snapshot supported global developer-tool configuration into a linked Git
# repository and push the resulting commit.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backup-common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/backup-common.sh"

usage() {
    echo "Usage:"
    echo "  lazy backup [--repository <url>]"
    echo ""
    echo "Archive detected Claude and Codex instructions, skills, rules, and custom"
    echo "agents, then push them to the linked Git repository. The first"
    echo "run asks for the repository address; later runs reuse that link."
    echo ""
    echo "Credentials, chat history, sessions, plugins, and shell config are excluded."
    echo "Skills can contain scripts, so a private repository is still recommended."
    echo ""
    echo "Options:"
    echo "  --repository <url>  Link this repository on the first run"
    echo "  -h, --help          Show this help"
    echo ""
    echo "To change repository, remove both paths and run backup again:"
    echo "  ~/.config/lazy/backup-repository"
    echo "  ~/.local/share/lazy/backup-repository"
}

REQUESTED_REPOSITORY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repository|--repo)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --repository needs an address." >&2
                exit 1
            fi
            REQUESTED_REPOSITORY="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: Unexpected argument -> $1" >&2; echo ""; usage; exit 1 ;;
    esac
    shift
done

backup_common_init
backup_require_tools || exit 1
backup_ensure_repository "$REQUESTED_REPOSITORY" || exit 1
backup_update_checkout || exit 1

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lazy-backup-build.XXXXXX" 2>/dev/null)"
if [ -z "$BUILD_DIR" ] || [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Could not create a temporary directory." >&2
    exit 1
fi

cleanup() {
    case "$BUILD_DIR" in
        "${TMPDIR:-/tmp}"/lazy-backup-build.*) rm -rf -- "$BUILD_DIR" ;;
        *) echo "Warning: Refusing to remove unexpected temporary path: $BUILD_DIR" >&2 ;;
    esac
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR/items"
MANIFEST="$BUILD_DIR/items/manifest.tsv"
: > "$MANIFEST"
ITEM_COUNT=0

while IFS=$'\t' read -r item_id item_path item_label; do
    source_path="$HOME/$item_path"
    if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
        continue
    fi

    printf '  Archiving %s\n' "$item_path"
    if ! tar -cf "$BUILD_DIR/items/$item_id.tar" -C "$HOME" "$item_path"; then
        echo "Error: Could not archive $source_path" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\n' "$item_id" "$item_path" "$item_label" >> "$MANIFEST"
    ITEM_COUNT=$((ITEM_COUNT + 1))
done < <(backup_registry)

if [ "$ITEM_COUNT" -eq 0 ]; then
    echo "Info: No supported configuration was found under $HOME."
    exit 0
fi

NEW_ITEMS="$BACKUP_REPO_DIR/.lazy-items-new.$$"
OLD_ITEMS="$BACKUP_REPO_DIR/.lazy-items-old.$$"
mv -- "$BUILD_DIR/items" "$NEW_ITEMS" || exit 1

if [ -e "$BACKUP_REPO_DIR/items" ]; then
    mv -- "$BACKUP_REPO_DIR/items" "$OLD_ITEMS" || exit 1
fi
if ! mv -- "$NEW_ITEMS" "$BACKUP_REPO_DIR/items"; then
    [ ! -e "$OLD_ITEMS" ] || mv -- "$OLD_ITEMS" "$BACKUP_REPO_DIR/items"
    exit 1
fi
if [ -e "$OLD_ITEMS" ]; then
    case "$OLD_ITEMS" in
        "$BACKUP_REPO_DIR"/.lazy-items-old.*) rm -rf -- "$OLD_ITEMS" ;;
        *) echo "Error: Refusing to remove unexpected old snapshot path." >&2; exit 1 ;;
    esac
fi

# Archives are binary even when their payload happens to look like text. Keep
# the manifest at LF on every platform so Git Bash cannot rewrite either form.
printf 'items/*.tar -text\nitems/manifest.tsv text eol=lf\n' > "$BACKUP_REPO_DIR/.gitattributes"

git -C "$BACKUP_REPO_DIR" add -A -- .gitattributes items || exit 1

push_backup() {
    if git -C "$BACKUP_REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        git -C "$BACKUP_REPO_DIR" push
    else
        git -C "$BACKUP_REPO_DIR" push -u origin HEAD
    fi
}

if git -C "$BACKUP_REPO_DIR" diff --cached --quiet --exit-code; then
    # A previous run may have committed successfully but failed to push. Retry
    # even when today's filesystem snapshot is identical.
    push_backup || exit 1
    echo "Backup is already up to date ($ITEM_COUNT items)."
    exit 0
fi

if ! git -C "$BACKUP_REPO_DIR" config user.name >/dev/null 2>&1; then
    git -C "$BACKUP_REPO_DIR" config user.name "lazy backup"
fi
if ! git -C "$BACKUP_REPO_DIR" config user.email >/dev/null 2>&1; then
    git -C "$BACKUP_REPO_DIR" config user.email "lazy-backup@localhost"
fi

BACKUP_HOST="$(hostname 2>/dev/null || echo machine)"
COMMIT_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
git -C "$BACKUP_REPO_DIR" commit -m "lazy backup: $COMMIT_STAMP ($BACKUP_HOST)" || exit 1
push_backup || exit 1

echo "Backup complete: $ITEM_COUNT items pushed."
