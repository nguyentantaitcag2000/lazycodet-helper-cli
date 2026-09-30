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
    all) cat ;;
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

# First use links an existing (possibly empty) remote and snapshots only the
# Claude/Codex agent allowlist. Even nested skill metadata is preserved.
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
[ ! -e "$SOURCE_REPO/items/claude-home.tar" ] || fail "broad Claude home archive was created"
[ ! -e "$SOURCE_REPO/items/codex-home.tar" ] || fail "broad Codex home archive was created"
tar -tf "$SOURCE_REPO/items/claude-skills.tar" | grep -qF '.claude/skills/demo/.git/config' ||
    fail "nested skill metadata was not archived"
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

# Restore on a new machine: fzf receives checkbox behavior, defaults all rows to
# selected, and the command replaces each selected item only after fzf returns.
RESTORE_HOME="$TEST_ROOT/restore-home"
RESTORE_CONFIG="$TEST_ROOT/restore-config"
RESTORE_STATE="$TEST_ROOT/restore-state"
RESTORE_REPO="$RESTORE_STATE/repository"
FZF_ARGS="$TEST_ROOT/fzf-args"
mkdir -p "$RESTORE_HOME/.claude/projects/demo" "$RESTORE_HOME/.codex/sessions"
printf 'local-claude\n' > "$RESTORE_HOME/.claude/CLAUDE.md"
printf 'local-codex\n' > "$RESTORE_HOME/.codex/AGENTS.md"
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
[ "$(cat "$RESTORE_HOME/.claude/.credentials.json")" = "keep-claude-token" ] || fail "Claude credentials were changed"
[ "$(cat "$RESTORE_HOME/.claude/projects/demo/history.json")" = "keep-claude-chat" ] || fail "Claude history was changed"
[ "$(cat "$RESTORE_HOME/.codex/auth.json")" = "keep-codex-token" ] || fail "Codex credentials were changed"
[ "$(cat "$RESTORE_HOME/.codex/sessions/chat.jsonl")" = "keep-codex-chat" ] || fail "Codex history was changed"
assert_file_has "$FZF_ARGS" "--multi"
assert_file_has "$FZF_ARGS" "load:select-all"
assert_file_lacks "$FZF_ARGS" "start:select-all"
assert_file_has "$FZF_ARGS" "space:toggle+down"
find "$RESTORE_STATE/restore-backups" -name 'claude-instructions.tar' -print -quit | grep -q . ||
    fail "restore did not preserve the previous files"

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

echo "backup/restore tests passed"
