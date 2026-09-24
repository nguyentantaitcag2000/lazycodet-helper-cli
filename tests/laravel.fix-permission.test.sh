#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${SCRIPT_DIR}/../commands/laravel.fix-permission.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-laravel-perm-test.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-laravel-perm-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_has() {
    printf '%s\n' "$1" | grep -qF -- "$2" || fail "expected output to contain: $2"$'\n'"$1"
}

assert_mode() {
    local actual
    actual="$(stat -c %a "$1")"
    [ "$actual" = "$2" ] || fail "expected mode $2 on $1, got $actual"
}

# Runs the command and records its exit status in STATUS; output goes to OUT.
run_cmd() {
    STATUS=0
    OUT="$(bash "$COMMAND" "$@" </dev/null 2>&1)" || STATUS=$?
}

MY_GID="$(id -g)"

# A monorepo holding a Laravel API one level down, the layout the command has to
# find from the repository root.
MONO="$TEST_ROOT/mono"
APP="$MONO/api"
mkdir -p "$APP/bootstrap/cache" "$APP/storage/logs" "$APP/storage/framework/views" "$APP/storage/app"
printf '#!/usr/bin/env php\n' > "$APP/artisan"
printf '<?php\n' > "$APP/bootstrap/app.php"
printf '*\n!.gitignore\n' > "$APP/bootstrap/cache/.gitignore"
printf '*\n!.gitignore\n' > "$APP/storage/logs/.gitignore"
printf '*\n!.gitignore\n' > "$APP/storage/framework/views/.gitignore"
printf '#!/bin/sh\n' > "$APP/storage/app/tool.sh"

git -C "$MONO" init -q
git -C "$MONO" config user.email test@example.com
git -C "$MONO" config user.name test
git -C "$MONO" config core.fileMode true
chmod 644 "$APP"/storage/logs/.gitignore "$APP"/storage/framework/views/.gitignore "$APP"/bootstrap/cache/.gitignore
chmod 755 "$APP/storage/app/tool.sh"
git -C "$MONO" add -A
git -C "$MONO" commit -qm init

# The situation the command exists for: a blanket chmod -R that put the execute
# bit on tracked files, a world-writable directory, and a log nobody else can write.
chmod -R 755 "$APP/storage" "$APP/bootstrap/cache"
chmod 777 "$APP/storage/framework"
printf 'log\n' > "$APP/storage/logs/laravel.log"
chmod 600 "$APP/storage/logs/laravel.log"

[ -n "$(git -C "$MONO" status --porcelain)" ] || fail "setup should leave Git-visible mode changes"

# --check reports and changes nothing.
run_cmd "$MONO" --check --group "$MY_GID"
[ "$STATUS" -eq 1 ] || fail "--check should exit 1 when something is wrong"
assert_has "$OUT" "Project:  $(cd -P "$APP" && pwd)"
assert_has "$OUT" "execute bit"
assert_has "$OUT" "world-writable"
assert_mode "$APP/storage/logs/.gitignore" 755

run_cmd "$MONO" --bogus
[ "$STATUS" -eq 1 ] || fail "an unknown option should exit 1"
assert_has "$OUT" "Unknown option"

run_cmd "$MONO" --group
[ "$STATUS" -eq 1 ] || fail "--group without a value should exit 1"

# Without a terminal and without -y it must refuse rather than guess.
run_cmd "$MONO" --group "$MY_GID"
[ "$STATUS" -eq 1 ] || fail "applying without -y and without a terminal should exit 1"
assert_mode "$APP/storage/logs/.gitignore" 755

# Fix it.
run_cmd "$MONO" -y --group "$MY_GID"
[ "$STATUS" -eq 0 ] || fail "fix should succeed"$'\n'"$OUT"
assert_has "$OUT" "Done."

assert_mode "$APP/storage" 2775
assert_mode "$APP/storage/framework" 2775
assert_mode "$APP/bootstrap/cache" 2775
assert_mode "$APP/storage/logs/.gitignore" 664
assert_mode "$APP/storage/logs/laravel.log" 664
# Executable in HEAD, so it keeps its x bit.
assert_mode "$APP/storage/app/tool.sh" 775

[ -z "$(git -C "$MONO" status --porcelain)" ] || fail "fix should leave no Git-visible changes: $(git -C "$MONO" status --porcelain)"

# A second run finds nothing to do, from inside the project this time.
run_cmd "$APP/storage/logs" --check --group "$MY_GID"
[ "$STATUS" -eq 0 ] || fail "--check after the fix should exit 0"$'\n'"$OUT"
assert_has "$OUT" "Everything is already in order."

# New files inherit the group through setgid, and group write through the
# default ACL when the filesystem supports it.
(umask 022 && printf 'new\n' > "$APP/storage/logs/laravel-new.log")
[ "$(stat -c %g "$APP/storage/logs/laravel-new.log")" = "$MY_GID" ] || fail "new file should inherit the directory group"
if command -v getfacl >/dev/null 2>&1 && getfacl -dpcn "$APP/storage/logs" 2>/dev/null | grep -q "^group:${MY_GID}:rw"; then
    perms="$(stat -c %A "$APP/storage/logs/laravel-new.log")"
    [ "${perms:5:1}" = "w" ] || fail "with a default ACL a new file should be group-writable, got $perms"
    [ "${perms:3:1}" = "-" ] || fail "a new file should not become executable, got $perms"
    echo "ACL path exercised"
else
    assert_has "$OUT" "without ACLs"
    echo "ACL path skipped (no setfacl/getfacl)"
fi

# A staged mode change is pointed out, since fixing the working tree cannot unstage it.
chmod +x "$APP/storage/logs/.gitignore"
git -C "$MONO" add "$APP/storage/logs/.gitignore"
run_cmd "$APP" --check --group "$MY_GID"
assert_has "$OUT" "restore --staged"
git -C "$MONO" reset -q

# Several projects below the starting directory: ask for one instead of picking.
mkdir -p "$MONO/admin/bootstrap" "$MONO/admin/storage" "$MONO/admin/bootstrap/cache"
printf '#!/usr/bin/env php\n' > "$MONO/admin/artisan"
printf '<?php\n' > "$MONO/admin/bootstrap/app.php"
run_cmd "$MONO" --check --group "$MY_GID"
[ "$STATUS" -eq 1 ] || fail "several projects should exit 1"
assert_has "$OUT" "Several Laravel projects"

run_cmd "$TEST_ROOT" --check
[ "$STATUS" -eq 1 ] || fail "a directory without Laravel should exit 1"

EMPTY="$TEST_ROOT/empty"
mkdir -p "$EMPTY"
run_cmd "$EMPTY" --check
[ "$STATUS" -eq 1 ] || fail "no project should exit 1"
assert_has "$OUT" "No Laravel project"

echo "laravel.fix-permission tests passed"
