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

# Replace the saved link, for example to move from an HTTPS address to the SSH
# address of the same repository. The local checkout is kept when the new
# remote is empty or shares its history, so a commit that failed to push is
# pushed on the next run. A checkout of unrelated history is moved aside and
# the new repository is cloned in its place by backup_ensure_repository.
backup_relink_repository() {
    local new_url="$1"
    local current_url
    local remote_refs
    local related=0
    local ref
    local previous_dir

    backup_validate_url "$new_url" || return 1

    current_url="$(backup_read_linked_url)"
    if [ "$current_url" = "$new_url" ]; then
        echo "Info: The backup repository is already linked to $new_url"
        return 0
    fi

    # Probe access before touching anything, so a mistyped address or a
    # missing permission leaves the current link working.
    echo "Checking access to $new_url"
    if ! remote_refs="$(git ls-remote -- "$new_url")"; then
        echo "Error: Could not access $new_url" >&2
        echo "       The saved backup repository link was not changed." >&2
        return 1
    fi

    if [ -e "$BACKUP_REPO_DIR" ]; then
        if ! git -C "$BACKUP_REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Error: Backup checkout exists but is not a Git repository:" >&2
            echo "       $BACKUP_REPO_DIR" >&2
            return 1
        fi
        backup_require_clean_checkout || return 1

        if [ -n "$remote_refs" ] && git -C "$BACKUP_REPO_DIR" rev-parse --verify -q HEAD >/dev/null; then
            if ! git -C "$BACKUP_REPO_DIR" fetch -q --no-tags -- "$new_url" '+refs/heads/*:refs/lazy-relink/*'; then
                echo "Error: Could not fetch $new_url" >&2
                return 1
            fi
            while IFS= read -r ref; do
                if git -C "$BACKUP_REPO_DIR" merge-base HEAD "$ref" >/dev/null 2>&1; then
                    related=1
                    break
                fi
            done < <(git -C "$BACKUP_REPO_DIR" for-each-ref --format='%(refname)' refs/lazy-relink/)
            git -C "$BACKUP_REPO_DIR" for-each-ref --format='delete %(refname)' refs/lazy-relink/ |
                git -C "$BACKUP_REPO_DIR" update-ref --stdin

            if [ "$related" -eq 0 ]; then
                if [ -n "$(git -C "$BACKUP_REPO_DIR" rev-list -n 1 HEAD --not --remotes=origin)" ]; then
                    echo "Error: $new_url has unrelated history, and the local backup" >&2
                    echo "       checkout has commits that were never pushed:" >&2
                    echo "       $BACKUP_REPO_DIR" >&2
                    echo "       Push or discard them before linking another repository." >&2
                    return 1
                fi
                previous_dir="$BACKUP_REPO_DIR.previous.$(date '+%Y%m%d%H%M%S')"
                mv -- "$BACKUP_REPO_DIR" "$previous_dir" || return 1
                echo "Moved the checkout of the previous repository to:"
                echo "  $previous_dir"
            fi
        fi
    fi

    if [ -e "$BACKUP_REPO_DIR" ]; then
        if git -C "$BACKUP_REPO_DIR" remote get-url origin >/dev/null 2>&1; then
            git -C "$BACKUP_REPO_DIR" remote set-url origin "$new_url" || return 1
        else
            git -C "$BACKUP_REPO_DIR" remote add origin "$new_url" || return 1
        fi
        # Remote-tracking refs still describe the old address. Refresh them,
        # and drop an upstream that the new remote does not have (an empty
        # repository) so the next push sets it again.
        if ! git -C "$BACKUP_REPO_DIR" fetch -q --prune origin; then
            echo "Error: Could not fetch $new_url" >&2
            return 1
        fi
        if git -C "$BACKUP_REPO_DIR" symbolic-ref -q HEAD >/dev/null &&
           ! backup_has_upstream; then
            git -C "$BACKUP_REPO_DIR" branch --unset-upstream >/dev/null 2>&1 || true
        fi
    fi

    backup_save_linked_url "$new_url" || {
        echo "Error: Could not save the backup repository link." >&2
        return 1
    }
    echo "Linked backup repository: $new_url"
}

backup_has_upstream() {
    git -C "$BACKUP_REPO_DIR" rev-parse --verify -q '@{upstream}' >/dev/null 2>&1
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

    # An empty remote has no HEAD to pull, and a checkout relinked to an empty
    # repository has no upstream yet. Once the first backup is pushed, the
    # branch tracks the remote and uses the normal rebase-based update path.
    if git -C "$BACKUP_REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1 &&
       backup_has_upstream; then
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
