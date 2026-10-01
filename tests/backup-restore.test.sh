#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-backup-restore-test.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-backup-restore-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_file_has() {
    grep -qF -- "$2" "$1" || fail "expected $1 to contain: $2"
}

assert_file_lacks() {
    if grep -qF -- "$2" "$1"; then
        fail "expected $1 to omit: $2"
    fi
}

MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/fzf" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "${LAZY_TEST_FZF_ARGS:?}"
case "${LAZY_TEST_FZF_MODE:-all}" in
    all) grep -v "^codex-rules$(printf '\t')" ;;
    match) grep -F -- "${LAZY_TEST_FZF_MATCH:?}" ;;
    empty) cat >/dev/null; exit 0 ;;
    cancel) cat >/dev/null; exit 130 ;;
    error) cat >/dev/null; exit 2 ;;
esac
EOF
chmod +x "$MOCK_BIN/fzf"

REMOTE="$TEST_ROOT/backup-remote.git"
git init -q --bare "$REMOTE"

SOURCE_HOME="$TEST_ROOT/source-home"
SOURCE_CONFIG="$TEST_ROOT/source-config"
SOURCE_STATE="$TEST_ROOT/source-state"
SOURCE_REPO="$SOURCE_STATE/repository"
mkdir -p \
    "$SOURCE_HOME/.claude/skills/demo/.git" \
    "$SOURCE_HOME/.claude/agents" \
    "$SOURCE_HOME/.claude/rules" \
    "$SOURCE_HOME/.claude/projects/demo" \
    "$SOURCE_HOME/.codex/rules" \
    "$SOURCE_HOME/.codex/sessions" \
    "$SOURCE_HOME/.codex/plugins/demo" \
    "$SOURCE_HOME/.agents/skills/demo"
printf 'claude-v1\n' > "$SOURCE_HOME/.claude/CLAUDE.md"
printf 'claude-local-v1\n' > "$SOURCE_HOME/.claude/CLAUDE.local.md"
printf 'claude-skill-v1\n' > "$SOURCE_HOME/.claude/skills/demo/SKILL.md"
printf 'nested-git-metadata\n' > "$SOURCE_HOME/.claude/skills/demo/.git/config"
printf 'reviewer-v1\n' > "$SOURCE_HOME/.claude/agents/reviewer.md"
printf 'claude-rule-v1\n' > "$SOURCE_HOME/.claude/rules/security.md"
printf 'codex-v1\n' > "$SOURCE_HOME/.codex/AGENTS.md"
printf 'codex-override-v1\n' > "$SOURCE_HOME/.codex/AGENTS.override.md"
printf 'codex-rule-v1\n' > "$SOURCE_HOME/.codex/rules/default.rules"
printf 'codex-skill-v1\n' > "$SOURCE_HOME/.agents/skills/demo/SKILL.md"

# Sensitive and unrelated state must remain outside the explicit allowlist.
printf 'claude-token\n' > "$SOURCE_HOME/.claude/.credentials.json"
printf 'claude-settings\n' > "$SOURCE_HOME/.claude/settings.json"
printf 'claude-chat\n' > "$SOURCE_HOME/.claude/projects/demo/history.json"
printf 'codex-token\n' > "$SOURCE_HOME/.codex/auth.json"
printf 'codex-chat\n' > "$SOURCE_HOME/.codex/sessions/chat.jsonl"
printf 'plugin-code\n' > "$SOURCE_HOME/.codex/plugins/demo/plugin.sh"
printf '[user]\n  name = Test User\n' > "$SOURCE_HOME/.gitconfig"

run_source() {
    HOME="$SOURCE_HOME" \
    LAZY_BACKUP_CONFIG_DIR="$SOURCE_CONFIG" \
    LAZY_BACKUP_STATE_DIR="$SOURCE_STATE" \
    LAZY_BACKUP_REPO_DIR="$SOURCE_REPO" \
    PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" "$@"
}

# The default folder format links an existing (possibly empty) remote and
# snapshots only the Claude/Codex allowlist as reviewable files.
run_source backup --repository "$REMOTE" > "$TEST_ROOT/backup-first.out"
[ -f "$SOURCE_CONFIG/backup-repository" ] || fail "repository link was not saved"
[ "$(cat "$SOURCE_CONFIG/backup-repository")" = "$REMOTE" ] || fail "saved repository link is wrong"
[ -f "$SOURCE_REPO/items/manifest.tsv" ] || fail "backup manifest was not created"
assert_file_has "$SOURCE_REPO/items/manifest.tsv" $'claude-instructions\t.claude/CLAUDE.md'
assert_file_has "$SOURCE_REPO/items/manifest.tsv" $'claude-skills\t.claude/skills'
assert_file_has "$SOURCE_REPO/items/manifest.tsv" $'claude-rules\t.claude/rules'
assert_file_has "$SOURCE_REPO/items/manifest.tsv" $'codex-instructions\t.codex/AGENTS.md'
assert_file_has "$SOURCE_REPO/items/manifest.tsv" $'codex-skills\t.agents/skills'
assert_file_has "$SOURCE_REPO/items/manifest.tsv" $'codex-rules\t.codex/rules'
assert_file_lacks "$SOURCE_REPO/items/manifest.tsv" '.credentials.json'
assert_file_lacks "$SOURCE_REPO/items/manifest.tsv" 'sessions'
assert_file_lacks "$SOURCE_REPO/items/manifest.tsv" 'plugins'
assert_file_lacks "$SOURCE_REPO/items/manifest.tsv" '.gitconfig'
[ "$(cat "$SOURCE_REPO/items/format")" = "folder-v1" ] || fail "folder format was not recorded"
[ "$(cat "$SOURCE_REPO/items/files/.claude/CLAUDE.md")" = "claude-v1" ] ||
    fail "Claude instructions were not stored as a reviewable file"
[ "$(cat "$SOURCE_REPO/items/files/.agents/skills/demo/SKILL.md")" = "codex-skill-v1" ] ||
    fail "Codex skill was not stored as a reviewable file"
[ ! -e "$SOURCE_REPO/items/claude-home.tar" ] || fail "broad Claude home archive was created"
[ ! -e "$SOURCE_REPO/items/codex-home.tar" ] || fail "broad Codex home archive was created"
[ ! -e "$SOURCE_REPO/items/claude-skills.tar" ] || fail "default backup created tar archives"
[ ! -e "$SOURCE_REPO/items/files/.claude/skills/demo/.git" ] ||
    fail "folder backup retained nested Git metadata"
git --git-dir="$REMOTE" rev-parse --verify HEAD >/dev/null || fail "first backup was not pushed"

# Once linked, no repository prompt is needed. Changed snapshots create and
# push another commit; unchanged snapshots do not create a third one.
FIRST_HEAD="$(git --git-dir="$REMOTE" rev-parse HEAD)"
printf 'claude-v2\n' > "$SOURCE_HOME/.claude/CLAUDE.md"
printf 'codex-v2\n' > "$SOURCE_HOME/.codex/AGENTS.md"
run_source backup > "$TEST_ROOT/backup-second.out"
SECOND_HEAD="$(git --git-dir="$REMOTE" rev-parse HEAD)"
[ "$SECOND_HEAD" != "$FIRST_HEAD" ] || fail "changed backup did not create a commit"
run_source backup > "$TEST_ROOT/backup-unchanged.out"
[ "$(git --git-dir="$REMOTE" rev-parse HEAD)" = "$SECOND_HEAD" ] ||
    fail "unchanged backup created a commit"
assert_file_has "$TEST_ROOT/backup-unchanged.out" "already up to date"

# The archive format preserves metadata that cannot live inside the outer Git
# repository. Switching formats replaces the snapshot cleanly, and switching
# back restores the reviewable folder layout.
FOLDER_HEAD="$(git --git-dir="$REMOTE" rev-parse HEAD)"
run_source backup --format archive > "$TEST_ROOT/backup-archive.out"
[ "$(cat "$SOURCE_REPO/items/format")" = "archive-v1" ] || fail "archive format was not recorded"
[ ! -e "$SOURCE_REPO/items/files" ] || fail "folder snapshot survived archive switch"
tar -tf "$SOURCE_REPO/items/claude-skills.tar" | grep -qF '.claude/skills/demo/.git/config' ||
    fail "archive format did not preserve nested skill metadata"
[ "$(git --git-dir="$REMOTE" rev-parse HEAD)" != "$FOLDER_HEAD" ] ||
    fail "switching to archive format did not create a commit"

run_source backup --format=folder > "$TEST_ROOT/backup-folder-again.out"
[ "$(cat "$SOURCE_REPO/items/format")" = "folder-v1" ] || fail "folder format was not restored"
[ -f "$SOURCE_REPO/items/files/.codex/AGENTS.md" ] || fail "folder snapshot was not recreated"
[ ! -e "$SOURCE_REPO/items/codex-instructions.tar" ] || fail "archive survived folder switch"

if run_source backup --format invalid > "$TEST_ROOT/backup-invalid.out" 2>&1; then
    fail "unsupported backup format was accepted"
fi
assert_file_has "$TEST_ROOT/backup-invalid.out" "Unsupported backup format"

# Restore on a new machine: fzf defaults standard rows to selected but leaves
# security-sensitive Codex command rules unchecked.
RESTORE_HOME="$TEST_ROOT/restore-home"
RESTORE_CONFIG="$TEST_ROOT/restore-config"
RESTORE_STATE="$TEST_ROOT/restore-state"
RESTORE_REPO="$RESTORE_STATE/repository"
FZF_ARGS="$TEST_ROOT/fzf-args"
mkdir -p "$RESTORE_HOME/.claude/projects/demo" "$RESTORE_HOME/.codex/rules" "$RESTORE_HOME/.codex/sessions"
printf 'local-claude\n' > "$RESTORE_HOME/.claude/CLAUDE.md"
printf 'local-codex\n' > "$RESTORE_HOME/.codex/AGENTS.md"
printf 'keep-local-codex-rule\n' > "$RESTORE_HOME/.codex/rules/default.rules"
printf 'keep-claude-token\n' > "$RESTORE_HOME/.claude/.credentials.json"
printf 'keep-claude-chat\n' > "$RESTORE_HOME/.claude/projects/demo/history.json"
printf 'keep-codex-token\n' > "$RESTORE_HOME/.codex/auth.json"
printf 'keep-codex-chat\n' > "$RESTORE_HOME/.codex/sessions/chat.jsonl"

run_restore() {
    HOME="$RESTORE_HOME" \
    LAZY_BACKUP_CONFIG_DIR="$RESTORE_CONFIG" \
    LAZY_BACKUP_STATE_DIR="$RESTORE_STATE" \
    LAZY_BACKUP_REPO_DIR="$RESTORE_REPO" \
    LAZY_TEST_FZF_ARGS="$FZF_ARGS" \
    PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" "$@"
}

run_restore restore --repository "$REMOTE" > "$TEST_ROOT/restore-all.out"
[ "$(cat "$RESTORE_HOME/.claude/CLAUDE.md")" = "claude-v2" ] || fail "Claude instructions were not restored"
[ "$(cat "$RESTORE_HOME/.codex/AGENTS.md")" = "codex-v2" ] || fail "Codex instructions were not restored"
[ "$(cat "$RESTORE_HOME/.codex/rules/default.rules")" = "keep-local-codex-rule" ] ||
    fail "default restore replaced unchecked Codex command rules"
[ "$(cat "$RESTORE_HOME/.claude/skills/demo/SKILL.md")" = "claude-skill-v1" ] ||
    fail "Claude skill was not restored from folder format"
[ ! -e "$RESTORE_HOME/.claude/skills/demo/.git" ] ||
    fail "folder restore unexpectedly created nested Git metadata"
[ "$(cat "$RESTORE_HOME/.claude/.credentials.json")" = "keep-claude-token" ] || fail "Claude credentials were changed"
[ "$(cat "$RESTORE_HOME/.claude/projects/demo/history.json")" = "keep-claude-chat" ] || fail "Claude history was changed"
[ "$(cat "$RESTORE_HOME/.codex/auth.json")" = "keep-codex-token" ] || fail "Codex credentials were changed"
[ "$(cat "$RESTORE_HOME/.codex/sessions/chat.jsonl")" = "keep-codex-chat" ] || fail "Codex history was changed"
assert_file_has "$FZF_ARGS" "--multi"
assert_file_has "$FZF_ARGS" "load:select-all+last+deselect+first"
assert_file_lacks "$FZF_ARGS" "start:select-all"
assert_file_has "$FZF_ARGS" "space:toggle+down"
assert_file_has "$FZF_ARGS" "Codex command rules are unchecked"
find "$RESTORE_STATE/restore-backups" -name 'claude-instructions.tar' -print -quit | grep -q . ||
    fail "restore did not preserve the previous files"

# Command rules remain available when the user explicitly checks that row.
LAZY_TEST_FZF_MODE=match LAZY_TEST_FZF_MATCH="$(printf 'codex-rules\t')" \
    run_restore restore > "$TEST_ROOT/restore-codex-rules.out"
[ "$(cat "$RESTORE_HOME/.codex/rules/default.rules")" = "codex-rule-v1" ] ||
    fail "explicitly selected Codex command rules were not restored"

# Space/uncheck behavior is represented by fzf returning only the checked row.
# The command must not touch an unchecked group.
printf 'local-claude-again\n' > "$RESTORE_HOME/.claude/CLAUDE.md"
printf 'local-codex-again\n' > "$RESTORE_HOME/.codex/AGENTS.md"
LAZY_TEST_FZF_MODE=match LAZY_TEST_FZF_MATCH="$(printf 'claude-instructions\t')" \
    run_restore restore > "$TEST_ROOT/restore-selected.out"
[ "$(cat "$RESTORE_HOME/.claude/CLAUDE.md")" = "claude-v2" ] ||
    fail "checked item was not restored"
[ "$(cat "$RESTORE_HOME/.codex/AGENTS.md")" = "local-codex-again" ] ||
    fail "unchecked item was changed"

# Esc/cancel and an empty Enter selection both leave the home directory alone.
printf 'cancelled-value\n' > "$RESTORE_HOME/.claude/CLAUDE.md"
LAZY_TEST_FZF_MODE=cancel run_restore restore > "$TEST_ROOT/restore-cancel.out"
[ "$(cat "$RESTORE_HOME/.claude/CLAUDE.md")" = "cancelled-value" ] ||
    fail "Esc cancellation changed files"
assert_file_has "$TEST_ROOT/restore-cancel.out" "Cancelled."
LAZY_TEST_FZF_MODE=empty run_restore restore > "$TEST_ROOT/restore-empty.out"
[ "$(cat "$RESTORE_HOME/.claude/CLAUDE.md")" = "cancelled-value" ] ||
    fail "empty Enter selection changed files"

# Restore auto-detects archive snapshots too, so changing backup formats does
# not require a matching restore option.
run_source backup --format archive > "$TEST_ROOT/backup-archive-restore.out"
printf 'local-codex-before-archive-restore\n' > "$RESTORE_HOME/.codex/AGENTS.md"
LAZY_TEST_FZF_MODE=match LAZY_TEST_FZF_MATCH="$(printf 'codex-instructions\t')" \
    run_restore restore > "$TEST_ROOT/restore-archive.out"
[ "$(cat "$RESTORE_HOME/.codex/AGENTS.md")" = "codex-v2" ] ||
    fail "Codex instructions were not restored from archive format"

# A first run without --repository obtains the address from stdin and retains it.
PROMPT_HOME="$TEST_ROOT/prompt-home"
PROMPT_CONFIG="$TEST_ROOT/prompt-config"
PROMPT_STATE="$TEST_ROOT/prompt-state"
mkdir -p "$PROMPT_HOME/.codex"
printf 'prompt-instructions\n' > "$PROMPT_HOME/.codex/AGENTS.md"
printf '%s\n' "$REMOTE" | \
    HOME="$PROMPT_HOME" \
    LAZY_BACKUP_CONFIG_DIR="$PROMPT_CONFIG" \
    LAZY_BACKUP_STATE_DIR="$PROMPT_STATE" \
    PATH="$MOCK_BIN:$PATH" \
        bash "$CLI" backup > "$TEST_ROOT/backup-prompt.out"
[ "$(cat "$PROMPT_CONFIG/backup-repository")" = "$REMOTE" ] ||
    fail "prompted repository address was not retained"

# --relink and --repository express different intents and cannot be combined.
if run_source backup --repository "$REMOTE" --relink "$REMOTE" > "$TEST_ROOT/relink-both.out" 2>&1; then
    fail "--repository and --relink were accepted together"
fi
assert_file_has "$TEST_ROOT/relink-both.out" "not both"

# An unreachable address is rejected before the saved link or checkout change.
if run_source backup --relink "$TEST_ROOT/missing.git" > "$TEST_ROOT/relink-missing.out" 2>&1; then
    fail "relink to an unreachable repository succeeded"
fi
assert_file_has "$TEST_ROOT/relink-missing.out" "link was not changed"
[ "$(cat "$SOURCE_CONFIG/backup-repository")" = "$REMOTE" ] ||
    fail "failed relink changed the saved link"
[ "$(git -C "$SOURCE_REPO" remote get-url origin)" = "$REMOTE" ] ||
    fail "failed relink changed the checkout origin"

# Another address for the same repository (HTTPS -> SSH in practice) keeps the
# checkout, so a commit whose push failed is delivered by the relinked run.
SAME_URL="file://$REMOTE"
printf 'unpushed\n' > "$SOURCE_REPO/unpushed-note"
git -C "$SOURCE_REPO" add unpushed-note
git -C "$SOURCE_REPO" -c user.name=t -c user.email=t@localhost \
    commit -q -m "push failed earlier"
run_source backup --relink "$SAME_URL" > "$TEST_ROOT/relink-same.out"
[ "$(cat "$SOURCE_CONFIG/backup-repository")" = "$SAME_URL" ] || fail "relink did not save the new address"
[ "$(git -C "$SOURCE_REPO" remote get-url origin)" = "$SAME_URL" ] || fail "relink did not update origin"
git --git-dir="$REMOTE" log --format=%s HEAD | grep -x "push failed earlier" >/dev/null ||
    fail "relinked backup did not push the previously unpushed commit"
run_source backup --relink "$SAME_URL" > "$TEST_ROOT/relink-same-again.out"
assert_file_has "$TEST_ROOT/relink-same-again.out" "already linked"

# An empty repository receives the existing backup history, and later runs
# track it normally.
EMPTY_REMOTE="$TEST_ROOT/backup-empty.git"
git init -q --bare "$EMPTY_REMOTE"
run_source backup --relink "$EMPTY_REMOTE" > "$TEST_ROOT/relink-empty.out"
git --git-dir="$EMPTY_REMOTE" log --format=%s HEAD | grep -x "push failed earlier" >/dev/null ||
    fail "relink to an empty repository did not migrate the backup history"
printf 'claude-v3\n' > "$SOURCE_HOME/.claude/CLAUDE.md"
run_source backup > "$TEST_ROOT/relink-empty-next.out"
[ "$(git --git-dir="$EMPTY_REMOTE" show HEAD:items/files/.claude/CLAUDE.md)" = "claude-v3" ] ||
    fail "backup after relinking to an empty repository was not pushed"

# A repository with unrelated history gets a fresh checkout; the previous one
# is moved aside rather than deleted.
OTHER_REMOTE="$TEST_ROOT/backup-other.git"
OTHER_SEED="$TEST_ROOT/other-seed"
git init -q --bare "$OTHER_REMOTE"
git init -q "$OTHER_SEED"
git -C "$OTHER_SEED" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m seed
git -C "$OTHER_SEED" push -q "$OTHER_REMOTE" HEAD:refs/heads/main
git --git-dir="$OTHER_REMOTE" symbolic-ref HEAD refs/heads/main
OTHER_SEED_HEAD="$(git -C "$OTHER_SEED" rev-parse HEAD)"
run_source backup --relink "$OTHER_REMOTE" > "$TEST_ROOT/relink-other.out"
find "$SOURCE_STATE" -maxdepth 1 -name 'repository.previous.*' -print -quit | grep -q . ||
    fail "checkout of unrelated history was not moved aside"
git --git-dir="$OTHER_REMOTE" merge-base --is-ancestor "$OTHER_SEED_HEAD" HEAD ||
    fail "backup to an unrelated repository did not build on its history"
[ "$(git --git-dir="$OTHER_REMOTE" show HEAD:items/files/.claude/CLAUDE.md)" = "claude-v3" ] ||
    fail "backup to an unrelated repository was not pushed"

# Moving aside is refused when it would strand commits that were never pushed.
git -C "$SOURCE_REPO" -c user.name=t -c user.email=t@localhost \
    commit -q --allow-empty -m "not pushed"
if run_source backup --relink "$REMOTE" > "$TEST_ROOT/relink-unpushed.out" 2>&1; then
    fail "relink stranded unpushed commits"
fi
assert_file_has "$TEST_ROOT/relink-unpushed.out" "never pushed"
[ "$(cat "$SOURCE_CONFIG/backup-repository")" = "$OTHER_REMOTE" ] ||
    fail "refused relink changed the saved link"

# Restore accepts the same option.
printf 'local-before-relink-restore\n' > "$RESTORE_HOME/.claude/CLAUDE.md"
LAZY_TEST_FZF_MODE=match LAZY_TEST_FZF_MATCH="$(printf 'claude-instructions\t')" \
    run_restore restore --relink "$EMPTY_REMOTE" > "$TEST_ROOT/restore-relink.out"
[ "$(cat "$RESTORE_CONFIG/backup-repository")" = "$EMPTY_REMOTE" ] ||
    fail "restore --relink did not save the new address"
[ "$(cat "$RESTORE_HOME/.claude/CLAUDE.md")" = "claude-v3" ] ||
    fail "restore --relink did not restore from the relinked repository"

echo "backup/restore tests passed"
