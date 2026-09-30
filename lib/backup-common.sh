#!/bin/bash
# Shared repository and item registry helpers for `lazy backup` and
# `lazy restore`. This file is sourced; callers decide when to exit.

backup_registry() {
    cat <<'EOF'
claude-instructions	.claude/CLAUDE.md	Claude Code global instructions
claude-local-instructions	.claude/CLAUDE.local.md	Claude Code private global instructions
claude-skills	.claude/skills	Claude Code skills
claude-agents	.claude/agents	Claude Code custom agents
claude-rules	.claude/rules	Claude Code rules
codex-instructions	.codex/AGENTS.md	Codex global instructions
codex-override	.codex/AGENTS.override.md	Codex global override instructions
codex-skills	.agents/skills	Codex skills
codex-rules	.codex/rules	Codex command rules
EOF
}

backup_registry_path() {
    local wanted="$1"
    local item_id
    local item_path

    while IFS=$'\t' read -r item_id item_path _; do
        if [ "$item_id" = "$wanted" ]; then
            printf '%s' "$item_path"
            return 0
        fi
    done < <(backup_registry)
    return 1
}

backup_common_init() {
    : "${HOME:?HOME is not set}"

    BACKUP_CONFIG_DIR="${LAZY_BACKUP_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/lazy}"
    BACKUP_STATE_DIR="${LAZY_BACKUP_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/lazy}"
    BACKUP_REPO_DIR="${LAZY_BACKUP_REPO_DIR:-$BACKUP_STATE_DIR/backup-repository}"
    BACKUP_URL_FILE="$BACKUP_CONFIG_DIR/backup-repository"
}

backup_require_tools() {
    local tool
    for tool in git tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: $tool is required for lazy backup and restore." >&2
            return 1
        fi
    done
}

backup_read_linked_url() {
    local url=""

    if [ -f "$BACKUP_URL_FILE" ]; then
        IFS= read -r url < "$BACKUP_URL_FILE" || true
    fi

    if [ -z "$url" ] && git -C "$BACKUP_REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        url="$(git -C "$BACKUP_REPO_DIR" remote get-url origin 2>/dev/null || true)"
    fi

    printf '%s' "$url"
}

backup_validate_url() {
    case "$1" in
        '') echo "Error: Repository address must not be empty." >&2; return 1 ;;
        *$'\n'*|*$'\r'*) echo "Error: Repository address must be one line." >&2; return 1 ;;
    esac
}

backup_save_linked_url() {
    local url="$1"
    local temp_file

    mkdir -p "$BACKUP_CONFIG_DIR" || return 1
    temp_file="$BACKUP_URL_FILE.tmp.$$"
    (umask 077; printf '%s\n' "$url" > "$temp_file") || return 1
    mv -f -- "$temp_file" "$BACKUP_URL_FILE"
}

# Resolve or establish the one-time repository link. An existing checkout's
# origin also counts as a link, which lets a copied data directory keep working
# even when its small config file is missing.
backup_ensure_repository() {
    local requested_url="${1:-}"
    local linked_url
    local origin_url=""
    local repo_parent
    local repo_name

    linked_url="$(backup_read_linked_url)"
    if [ -n "$requested_url" ]; then
        backup_validate_url "$requested_url" || return 1
        if [ -n "$linked_url" ] && [ "$linked_url" != "$requested_url" ]; then
            echo "Error: A different backup repository is already linked." >&2
            echo "       See 'lazy backup --help' before changing repositories." >&2
            return 1
        fi
        linked_url="$requested_url"
    fi

    if [ -z "$linked_url" ]; then
        printf 'Backup repository address: '
        if ! IFS= read -r linked_url; then
            echo "" >&2
            echo "Error: Could not read the repository address." >&2
            return 1
        fi
        backup_validate_url "$linked_url" || return 1
    fi

    if [ -e "$BACKUP_REPO_DIR" ]; then
        if ! git -C "$BACKUP_REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Error: Backup checkout exists but is not a Git repository:" >&2
            echo "       $BACKUP_REPO_DIR" >&2
            return 1
        fi
        origin_url="$(git -C "$BACKUP_REPO_DIR" remote get-url origin 2>/dev/null || true)"
        if [ -z "$origin_url" ]; then
            git -C "$BACKUP_REPO_DIR" remote add origin "$linked_url" || return 1
        elif [ "$origin_url" != "$linked_url" ]; then
            # Git Bash rewrites a local /c/... clone URL to C:/... in .git/config.
            # The saved link is the source of truth, so aligning origin is both
            # portable and stricter than guessing whether two strings are the
            # same platform-specific spelling of a path.
            git -C "$BACKUP_REPO_DIR" remote set-url origin "$linked_url" || return 1
        fi
    else
        repo_parent="$(dirname "$BACKUP_REPO_DIR")"
        repo_name="$(basename "$BACKUP_REPO_DIR")"
        mkdir -p "$repo_parent" || return 1
        if ! git -C "$repo_parent" clone -- "$linked_url" "$repo_name"; then
            echo "Error: Could not clone the backup repository." >&2
            return 1
        fi
    fi

    backup_save_linked_url "$linked_url" || {
        echo "Error: Could not save the backup repository link." >&2
        return 1
    }
}

backup_require_clean_checkout() {
    if [ -n "$(git -C "$BACKUP_REPO_DIR" status --porcelain 2>/dev/null)" ]; then
        echo "Error: The local backup checkout has uncommitted changes:" >&2
        echo "       $BACKUP_REPO_DIR" >&2
        echo "       Resolve them before running the command again." >&2
        return 1
    fi
}

backup_update_checkout() {
    backup_require_clean_checkout || return 1

    # An empty remote has no HEAD to pull. Once the first backup exists, clones
    # have an upstream and can use the normal rebase-based update path.
    if git -C "$BACKUP_REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
        if ! git -C "$BACKUP_REPO_DIR" pull --rebase; then
            echo "Error: Could not update the local backup checkout." >&2
            return 1
        fi
    fi
}

backup_validate_archive() {
    local archive="$1"
    local expected_path="$2"
    local member
    local found=0

    if [ ! -f "$archive" ] || [ -L "$archive" ]; then
        echo "Error: Backup archive is missing or unsafe: $archive" >&2
        return 1
    fi

    while IFS= read -r member; do
        [ -n "$member" ] || continue
        member=${member%/}
        case "$member" in
            "$expected_path"|"$expected_path"/*) found=1 ;;
            *)
                echo "Error: Archive contains a path outside $expected_path: $member" >&2
                return 1
                ;;
        esac
    done < <(tar -tf "$archive")

    if [ "$found" -ne 1 ]; then
        echo "Error: Backup archive is empty: $archive" >&2
        return 1
    fi
}
