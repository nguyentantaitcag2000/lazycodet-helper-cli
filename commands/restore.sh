#!/bin/bash
# Restore selected global configuration archives from the linked backup repo.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backup-common.sh disable=SC1091
source "${SCRIPT_DIR}/../lib/backup-common.sh"

usage() {
    echo "Usage:"
    echo "  lazy restore [--repository <url>]"
    echo ""
    echo "Fetch the linked backup and choose what to restore. All rows start checked;"
    echo "use Space to check/uncheck, Enter to restore, or Esc to cancel."
    echo ""
    echo "Options:"
    echo "  --repository <url>  Link this repository on a new machine"
    echo "  -h, --help          Show this help"
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
if ! command -v fzf >/dev/null 2>&1; then
    echo "Error: fzf is not installed." >&2
    echo "       Install it, then run 'lazy restore' again." >&2
    exit 1
fi

backup_ensure_repository "$REQUESTED_REPOSITORY" || exit 1
backup_update_checkout || exit 1

MANIFEST="$BACKUP_REPO_DIR/items/manifest.tsv"
if [ ! -s "$MANIFEST" ]; then
    echo "Error: The linked repository does not contain a lazy backup." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lazy-restore.XXXXXX" 2>/dev/null)"
if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "Error: Could not create a temporary directory." >&2
    exit 1
fi

RESTORE_IN_PROGRESS=0
RECOVERY_DIR=""
SELECTED_IDS=()
SELECTED_PATHS=()

rollback_restore() {
    local index
    local target
    local recovery_archive

    [ -n "$RECOVERY_DIR" ] || return 0
    echo "Restoring the pre-restore state after an error..." >&2
    for ((index = 0; index < ${#SELECTED_PATHS[@]}; index++)); do
        target="$HOME/${SELECTED_PATHS[$index]}"
        if [ -e "$target" ] || [ -L "$target" ]; then
            rm -rf -- "$target"
        fi
        recovery_archive="$RECOVERY_DIR/${SELECTED_IDS[$index]}.tar"
        if [ -f "$recovery_archive" ]; then
            tar -xf "$recovery_archive" -C "$HOME" || true
        fi
    done
}

cleanup() {
    if [ "$RESTORE_IN_PROGRESS" -eq 1 ]; then
        RESTORE_IN_PROGRESS=0
        rollback_restore
    fi
    case "$WORK_DIR" in
        "${TMPDIR:-/tmp}"/lazy-restore.*) rm -rf -- "$WORK_DIR" ;;
        *) echo "Warning: Refusing to remove unexpected temporary path: $WORK_DIR" >&2 ;;
    esac
}
trap cleanup EXIT

CHOICES="$WORK_DIR/choices"
: > "$CHOICES"
AVAILABLE_IDS=()
AVAILABLE_PATHS=()

while IFS=$'\t' read -r item_id item_path item_label; do
    [ -n "$item_id" ] || continue
    registered_path="$(backup_registry_path "$item_id" || true)"
    if [ -z "$registered_path" ] || [ "$registered_path" != "$item_path" ]; then
        echo "Error: Backup manifest contains an unknown item: $item_id" >&2
        exit 1
    fi
    archive="$BACKUP_REPO_DIR/items/$item_id.tar"
    backup_validate_archive "$archive" "$item_path" || exit 1
    AVAILABLE_IDS+=("$item_id")
    AVAILABLE_PATHS+=("$item_path")
    # This is a display label, not a shell path to expand.
    # shellcheck disable=SC2088
    printf -v display_path '~/%s' "$item_path"
    printf '%s\t%-22s %s\n' "$item_id" "$display_path" "$item_label" >> "$CHOICES"
done < "$MANIFEST"

if [ "${#AVAILABLE_IDS[@]}" -eq 0 ]; then
    echo "Error: The backup manifest has no restorable items." >&2
    exit 1
fi

# The start event can fire before streamed input has reached fzf, leaving no
# rows selected. Wait for the input load event before selecting them.
SELECTED_OUTPUT=$(fzf \
    --multi \
    --height=80% \
    --layout=reverse \
    --border \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --bind='load:select-all' \
    --bind='space:toggle+down' \
    --marker='x' \
    --prompt='Restore > ' \
    --header=$'All items are checked by default\nSPACE = check/uncheck | ENTER = restore | ESC = cancel' \
    < "$CHOICES")
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
    *) echo "Error: fzf could not open the restore picker." >&2; exit "$FZF_STATUS" ;;
esac

while IFS=$'\t' read -r selected_id _; do
    selected_index=-1
    for ((index = 0; index < ${#AVAILABLE_IDS[@]}; index++)); do
        if [ "${AVAILABLE_IDS[$index]}" = "$selected_id" ]; then
            selected_index=$index
            break
        fi
    done
    if [ "$selected_index" -lt 0 ]; then
        echo "Error: Could not read the selected items from fzf." >&2
        exit 1
    fi
    SELECTED_IDS+=("${AVAILABLE_IDS[$selected_index]}")
    SELECTED_PATHS+=("${AVAILABLE_PATHS[$selected_index]}")
done <<< "$SELECTED_OUTPUT"

# Validate and extract everything before the first home-directory change.
mkdir -p "$WORK_DIR/staged"
for ((index = 0; index < ${#SELECTED_IDS[@]}; index++)); do
    tar -xf "$BACKUP_REPO_DIR/items/${SELECTED_IDS[$index]}.tar" -C "$WORK_DIR/staged" || exit 1
    staged_path="$WORK_DIR/staged/${SELECTED_PATHS[$index]}"
    if [ ! -e "$staged_path" ] && [ ! -L "$staged_path" ]; then
        echo "Error: Archive did not extract ${SELECTED_PATHS[$index]}." >&2
        exit 1
    fi
done

RECOVERY_ROOT="$BACKUP_STATE_DIR/restore-backups"
RECOVERY_STAMP="$(date '+%Y%m%d-%H%M%S')-$$"
RECOVERY_DIR="$RECOVERY_ROOT/$RECOVERY_STAMP"
mkdir -p "$RECOVERY_DIR"
: > "$RECOVERY_DIR/manifest.tsv"

for ((index = 0; index < ${#SELECTED_IDS[@]}; index++)); do
    item_path="${SELECTED_PATHS[$index]}"
    target="$HOME/$item_path"
    if [ -e "$target" ] || [ -L "$target" ]; then
        tar -cf "$RECOVERY_DIR/${SELECTED_IDS[$index]}.tar" -C "$HOME" "$item_path" || exit 1
        printf '%s\t%s\n' "${SELECTED_IDS[$index]}" "$item_path" >> "$RECOVERY_DIR/manifest.tsv"
    fi
done

RESTORE_IN_PROGRESS=1
for ((index = 0; index < ${#SELECTED_IDS[@]}; index++)); do
    item_path="${SELECTED_PATHS[$index]}"
    target="$HOME/$item_path"
    staged_path="$WORK_DIR/staged/$item_path"
    if [ -e "$target" ] || [ -L "$target" ]; then
        rm -rf -- "$target" || exit 1
    fi
    mkdir -p "$(dirname "$target")" || exit 1
    mv -- "$staged_path" "$target" || exit 1
    printf '  Restored ~/%s\n' "$item_path"
done
RESTORE_IN_PROGRESS=0

echo "Restore complete: ${#SELECTED_IDS[@]} items."
echo "Previous files (when present): $RECOVERY_DIR"
