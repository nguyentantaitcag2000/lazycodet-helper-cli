#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-agent-sync.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-agent-sync.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

new_repo() {
    local repo="$1"

    mkdir -p "$repo"
    git -C "$repo" init -q
    printf '# Project instructions\n' > "$repo/CLAUDE.md"
}

FULL_REPO="$TEST_ROOT/full project"
new_repo "$FULL_REPO"
mkdir -p "$FULL_REPO/.claude/skills/demo"
printf '# Demo skill\n' > "$FULL_REPO/.claude/skills/demo/SKILL.md"
printf 'CLAUDE.md\n' > "$FULL_REPO/AGENTS.md"
mkdir -p "$FULL_REPO/.agents/skills/demo"
printf '# Demo skill\n' > "$FULL_REPO/.agents/skills/demo/SKILL.md"

if bash "$CLI" agent.sync "$FULL_REPO" --check >/dev/null 2>&1; then
    fail "check mode accepted generated copies instead of real symlinks"
fi

bash "$CLI" agent.sync "$FULL_REPO" >/dev/null
[ -L "$FULL_REPO/AGENTS.md" ] || fail "AGENTS.md was not created as a symlink"
[ "$(readlink "$FULL_REPO/AGENTS.md")" = "CLAUDE.md" ] || fail "AGENTS.md target is not relative"
[ -L "$FULL_REPO/.agents/skills/demo" ] || fail "skill was not created as a symlink"
[ "$(readlink "$FULL_REPO/.agents/skills/demo")" = "../../.claude/skills/demo" ] || fail "skill target is not relative"
[ "$(git -C "$FULL_REPO" config --bool --get core.symlinks)" = "true" ] || fail "core.symlinks is not true"

mkdir -p "$FULL_REPO/nested/path"
(
    cd "$FULL_REPO/nested/path"
    bash "$CLI" agent.sync --check >/dev/null
)

rm "$FULL_REPO/.claude/skills/demo/SKILL.md"
rmdir "$FULL_REPO/.claude/skills/demo"
bash "$CLI" agent.sync "$FULL_REPO" >/dev/null
[ ! -e "$FULL_REPO/.agents/skills/demo" ] || fail "stale managed skill was not removed"
bash "$CLI" agent.sync "$FULL_REPO" --check >/dev/null

EMPTY_REPO="$TEST_ROOT/no skills"
new_repo "$EMPTY_REPO"
bash "$CLI" agent.sync "$EMPTY_REPO" >/dev/null
[ -L "$EMPTY_REPO/AGENTS.md" ] || fail "project without skills did not link AGENTS.md"
bash "$CLI" agent.sync "$EMPTY_REPO" --check >/dev/null

PROTECTED_REPO="$TEST_ROOT/protected content"
new_repo "$PROTECTED_REPO"
printf 'Keep this independent file.\n' > "$PROTECTED_REPO/AGENTS.md"
if bash "$CLI" agent.sync "$PROTECTED_REPO" >/dev/null 2>&1; then
    fail "independent AGENTS.md was overwritten"
fi
grep -qxF 'Keep this independent file.' "$PROTECTED_REPO/AGENTS.md" || fail "independent content changed"

echo "agent.sync tests passed"
