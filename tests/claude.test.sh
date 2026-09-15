#!/bin/bash
#
# The valuable half of `lazy claude` is what it does to files nobody wants to
# lose: the live credentials, the archived copy of every other account, and
# ~/.claude.json. None of that can be exercised against a real login, so the
# test drives the command against a fake HOME, a fake account store, and a stub
# `claude` binary whose "browser sign-in" just writes a credentials file into
# whatever CLAUDE_CONFIG_DIR it was handed.
#
# The scenario that matters most is token rotation: Claude Code hands out a new
# refresh token every time it renews, so an account switched away from stays
# usable only if the rotated tokens were written back into its saved copy first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${SCRIPT_DIR}/../commands/claude.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-claude.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-claude.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_has() {
    printf '%s\n' "$1" | grep -qF -- "$2" || {
        printf '%s\n' "$1" >&2
        fail "expected output to contain: $2"
    }
}

assert_file_has() {
    grep -qF -- "$2" "$1" || {
        echo "--- $1 ---" >&2
        cat "$1" >&2
        fail "expected $1 to contain: $2"
    }
}

assert_file_lacks() {
    if grep -qF -- "$2" "$1"; then
        echo "--- $1 ---" >&2
        cat "$1" >&2
        fail "expected $1 to omit: $2"
    fi
}

# The command reads ~/.claude.json through node or python3, whichever it finds.
# Both readers have to behave identically, so the whole suite is replayed once
# per reader this machine actually has.
if [ -z "${LAZY_CLAUDE_JSON_RUNNER:-}" ]; then
    RUNNERS=()
    if command -v node >/dev/null 2>&1 && node -e '' >/dev/null 2>&1; then
        RUNNERS+=("node")
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
        RUNNERS+=("python3")
    fi

    if [ "${#RUNNERS[@]}" -eq 0 ]; then
        echo "SKIP: claude tests need node or python3"
        exit 0
    fi

    for runner in "${RUNNERS[@]}"; do
        echo "--- json reader: ${runner}"
        LAZY_CLAUDE_JSON_RUNNER="$runner" bash "${BASH_SOURCE[0]}"
    done
    exit 0
fi

JSON_RUNNER="$LAZY_CLAUDE_JSON_RUNNER"

FAKE_HOME="$TEST_ROOT/home"
STORE="$TEST_ROOT/store"
BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_HOME/.claude" "$BIN"

FUTURE=$(( ($(date +%s) + 7200) * 1000 ))
FAR_FUTURE=$(( ($(date +%s) + 2592000) * 1000 ))

# ---------------------------------------------------------------- the fixtures

write_credentials() {
    # <path> <token-suffix> <plan>
    cat > "$1" <<JSON
{
  "claudeAiOauth": {
    "accessToken": "at-$2",
    "refreshToken": "rt-$2",
    "expiresAt": $FUTURE,
    "refreshTokenExpiresAt": $FAR_FUTURE,
    "scopes": ["user:inference"],
    "subscriptionType": "$3",
    "organizationUuid": "org-$2"
  }
}
JSON
}

write_config() {
    # <path> <uuid> <email> <org> [extra top-level json]
    cat > "$1" <<JSON
{
  "userID": "uid-$2",
  "hasCompletedOnboarding": true,
  "cachedUsageUtilization": {"belongsTo": "$2"},
  "projects": {"/tmp/some-project": {"allowedTools": ["Bash"]}},
  "oauthAccount": {
    "accountUuid": "$2",
    "emailAddress": "$3",
    "organizationName": "$4"
  }
}
JSON
}

# The stub stands in for the OAuth browser flow: `claude auth login` writes the
# tokens and the account record into whatever config dir it was pointed at.
cat > "$BIN/claude" <<'STUB'
#!/bin/bash
set -eu
[ "${1:-}" = "auth" ] || exit 2
[ "${2:-}" = "login" ] || exit 2
if [ "${STUB_LOGIN_FAILS:-0}" = "1" ]; then
    echo "stub: sign-in abandoned" >&2
    exit 1
fi
mkdir -p "$CLAUDE_CONFIG_DIR"
cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<JSON
{
  "claudeAiOauth": {
    "accessToken": "at-$STUB_TOKEN",
    "refreshToken": "rt-$STUB_TOKEN",
    "expiresAt": $STUB_EXPIRES,
    "refreshTokenExpiresAt": $STUB_REFRESH_EXPIRES,
    "scopes": ["user:inference"],
    "subscriptionType": "$STUB_PLAN",
    "organizationUuid": "org-$STUB_TOKEN"
  }
}
JSON
cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<JSON
{
  "userID": "uid-$STUB_UUID",
  "hasCompletedOnboarding": true,
  "oauthAccount": {
    "accountUuid": "$STUB_UUID",
    "emailAddress": "$STUB_EMAIL",
    "organizationName": "$STUB_ORG"
  }
}
JSON
echo "stub: signed in as $STUB_EMAIL"
STUB
chmod +x "$BIN/claude"

run() {
    HOME="$FAKE_HOME" \
    PATH="$BIN:$PATH" \
    LAZY_CLAUDE_STORE="$STORE" \
    LAZY_CLAUDE_JSON_RUNNER="$JSON_RUNNER" \
    CLAUDE_CONFIG_DIR="" \
    NO_COLOR=1 \
        bash "$CMD" "$@" 2>&1
}

LIVE_CRED="$FAKE_HOME/.claude/.credentials.json"
LIVE_CONFIG="$FAKE_HOME/.claude.json"

# --------------------------------------------- the login already on the machine

write_credentials "$LIVE_CRED" "alpha-1" "max"
write_config "$LIVE_CONFIG" "uuid-alpha" "alpha@example.com" "Alpha Inc"

OUT="$(run --list)"
assert_has "$OUT" "saved the login you are signed in with as 'alpha'"
assert_has "$OUT" "alpha@example.com"
assert_has "$OUT" "max"
[ "$(run --current)" = "alpha" ] || fail "expected alpha to be the account in use"
assert_file_has "$STORE/alpha/credentials.json" "rt-alpha-1"

# An import must not disturb the login it read.
assert_file_has "$LIVE_CRED" "at-alpha-1"
assert_file_has "$LIVE_CONFIG" "/tmp/some-project"

# -------------------------------------------------------- adding a second login

OUT="$(STUB_TOKEN=beta-1 STUB_UUID=uuid-beta STUB_EMAIL=beta@example.com \
    STUB_ORG="Beta Ltd" STUB_PLAN=team STUB_EXPIRES=$FUTURE \
    STUB_REFRESH_EXPIRES=$FAR_FUTURE run --add -y)"
assert_has "$OUT" "saved as 'beta'"
assert_has "$OUT" "now signed in as 'beta'"

[ "$(run --current)" = "beta" ] || fail "expected beta to be the account in use"
assert_file_has "$LIVE_CRED" "at-beta-1"
assert_file_has "$LIVE_CONFIG" "beta@example.com"
# Everything in ~/.claude.json that is not account state survives the switch.
assert_file_has "$LIVE_CONFIG" "/tmp/some-project"
# Account-scoped caches do not.
assert_file_lacks "$LIVE_CONFIG" "cachedUsageUtilization"
# Alpha is archived untouched, with its own tokens.
assert_file_has "$STORE/alpha/credentials.json" "rt-alpha-1"
assert_file_has "$STORE/alpha/account.json" "alpha@example.com"

# The sign-in must have run in a throwaway dir - nothing may be left behind.
if ls -d "$STORE"/.pending.* >/dev/null 2>&1; then
    fail "the pending sign-in directory was not cleaned up"
fi

# ------------------------------------------ rotation: the reason this exists

# Claude Code renews beta's tokens and rotates the refresh token, exactly as it
# does in a real session.
write_credentials "$LIVE_CRED" "beta-2" "team"

OUT="$(run alpha -y)"
assert_has "$OUT" "now signed in as 'alpha'"

# The rotated pair must have been written back to beta before alpha replaced it.
# Restoring the pre-rotation copy is what gets an account logged out for good.
assert_file_has "$STORE/beta/credentials.json" "rt-beta-2"
assert_file_lacks "$STORE/beta/credentials.json" "rt-beta-1"
assert_file_has "$LIVE_CRED" "at-alpha-1"
assert_file_has "$LIVE_CONFIG" "alpha@example.com"

# And switching back hands beta the rotated tokens, not the ones it was added with.
OUT="$(run beta -y)"
assert_has "$OUT" "now signed in as 'beta'"
assert_file_has "$LIVE_CRED" "rt-beta-2"

# -------------------------------------------------------- a login made elsewhere

# Somebody ran `claude auth login` by hand: the live tokens now belong to an
# account no profile knows about. Overwriting beta's copy with them would lose
# beta for good, so the command must import instead.
write_credentials "$LIVE_CRED" "gamma-1" "pro"
write_config "$LIVE_CONFIG" "uuid-gamma" "gamma@example.com" "Gamma GmbH"

OUT="$(run --list)"
assert_has "$OUT" "the live login is not 'beta' any more"
assert_has "$OUT" "gamma@example.com"
assert_file_has "$STORE/beta/credentials.json" "rt-beta-2"
[ "$(run --current)" = "gamma" ] || fail "expected the adopted account to be in use"

# Signing in again as an account that is already saved refreshes it in place.
OUT="$(STUB_TOKEN=gamma-2 STUB_UUID=uuid-gamma STUB_EMAIL=gamma@example.com \
    STUB_ORG="Gamma GmbH" STUB_PLAN=pro STUB_EXPIRES=$FUTURE \
    STUB_REFRESH_EXPIRES=$FAR_FUTURE run --add -y)"
assert_has "$OUT" "saved as 'gamma'"
GAMMA_DIRS=("$STORE"/gamma*)
[ "${#GAMMA_DIRS[@]}" -eq 1 ] || fail "a duplicate profile was created for gamma"
assert_file_has "$STORE/gamma/credentials.json" "rt-gamma-2"

# ------------------------------------------------------- an abandoned sign-in

BEFORE="$(cat "$LIVE_CRED")"
set +e
OUT="$(STUB_LOGIN_FAILS=1 STUB_TOKEN=x STUB_UUID=x STUB_EMAIL=x STUB_ORG=x \
    STUB_PLAN=x STUB_EXPIRES=$FUTURE STUB_REFRESH_EXPIRES=$FAR_FUTURE \
    run --add -y)"
STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "an abandoned sign-in should fail"
assert_has "$OUT" "did not complete"
[ "$(cat "$LIVE_CRED")" = "$BEFORE" ] || fail "an abandoned sign-in changed the live login"
[ "$(run --current)" = "gamma" ] || fail "an abandoned sign-in changed the account in use"

# ------------------------------------------------------------------ a logout

# `claude auth logout` leaves a credentials file with an empty token behind.
# Archiving that would wipe the saved copy of the account it belongs to.
cp "$LIVE_CRED" "$TEST_ROOT/gamma-live.json"
cat > "$LIVE_CRED" <<'JSON'
{"claudeAiOauth": {"accessToken": "", "refreshToken": ""}}
JSON
run --list >/dev/null
assert_file_has "$STORE/gamma/credentials.json" "rt-gamma-2"
cp "$TEST_ROOT/gamma-live.json" "$LIVE_CRED"

# ------------------------------------------------- a login that cannot be saved

# Tokens that work but say nothing about whose they are cannot be archived, so
# switching would leave only the .lazy.bak copy of them. That has to be asked
# about rather than done.
cp "$LIVE_CONFIG" "$TEST_ROOT/gamma-config.json"
cat > "$LIVE_CONFIG" <<'JSON'
{"hasCompletedOnboarding": true, "projects": {}}
JSON
ANSWER="$TEST_ROOT/answer"
printf 'n\n' > "$ANSWER"
OUT="$(LAZY_CLAUDE_TTY_IN="$ANSWER" run beta)"
assert_has "$OUT" "could not be archived"
assert_has "$OUT" "Cancelled."
assert_file_has "$LIVE_CRED" "at-gamma-2"
cp "$TEST_ROOT/gamma-config.json" "$LIVE_CONFIG"

# ---------------------------------------------------------------- the picker

# The key handling is the part a user touches, and it cannot be driven through
# stdin: the picker reads the terminal directly so its drawing stays out of the
# captured output. LAZY_CLAUDE_TTY_IN/OUT stand in for that terminal.
KEYS="$TEST_ROOT/keys"
SCREEN="$TEST_ROOT/screen"

pick() {
    printf '%b' "$1" > "$KEYS"
    : > "$SCREEN"
    LAZY_CLAUDE_TTY_IN="$KEYS" LAZY_CLAUDE_TTY_OUT="$SCREEN" run -y
}

# alpha, beta, gamma, then the add row - gamma is in use, so that is where the
# cursor starts. One step up lands on beta.
OUT="$(pick '\033[A\n')"
assert_has "$OUT" "now signed in as 'beta'"
assert_file_has "$SCREEN" "up/down move   ENTER switch"
assert_file_has "$SCREEN" "add another account"
assert_file_has "$SCREEN" "> * gamma"
[ "$(run --current)" = "beta" ] || fail "the picker did not switch to beta"

# Wrapping: beta is in use now, one step up from it is alpha.
OUT="$(pick '\033[A\n')"
assert_has "$OUT" "now signed in as 'alpha'"

# Down from alpha is beta again, and j/k move too.
OUT="$(pick 'j\n')"
assert_has "$OUT" "now signed in as 'beta'"

# q leaves the login alone.
OUT="$(pick 'q')"
assert_has "$OUT" "Cancelled."
[ "$(run --current)" = "beta" ] || fail "quitting the picker changed the login"

# So does ESC on its own.
OUT="$(pick '\033')"
assert_has "$OUT" "Cancelled."

# The last row signs in to another account.
OUT="$(STUB_TOKEN=delta-1 STUB_UUID=uuid-delta STUB_EMAIL=delta@example.com \
    STUB_ORG="Delta SA" STUB_PLAN=max STUB_EXPIRES=$FUTURE \
    STUB_REFRESH_EXPIRES=$FAR_FUTURE pick '\033[B\033[B\n')"
assert_has "$OUT" "saved as 'delta'"
assert_has "$OUT" "now signed in as 'delta'"

OUT="$(run --remove delta -y)"
assert_has "$OUT" "forgot 'delta'"
# Forgetting the account in use leaves claude signed in as it, and says so.
assert_has "$OUT" "claude stays signed in as it"

# --------------------------------------------------------------------- removal

OUT="$(run --remove alpha -y)"
assert_has "$OUT" "forgot 'alpha'"
if [ -d "$STORE/alpha" ]; then
    fail "the removed profile is still on disk"
fi

OUT="$(run --remove nope -y || true)"
assert_has "$OUT" "No saved account named 'nope'"

OUT="$(run --list)"
assert_has "$OUT" "beta@example.com"
assert_has "$OUT" "gamma@example.com"

# ------------------------------------------------------------ unknown account

set +e
OUT="$(run does-not-exist -y)"
STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "switching to an unknown account should fail"
assert_has "$OUT" "No saved account named 'does-not-exist'"

# --------------------------------------------------------------- store hygiene

# Only where the filesystem actually carries POSIX modes. On the NTFS mount Git
# Bash runs against, chmod is accepted and then reported back as 755, so the
# assertion would fail on a correct implementation.
mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

PROBE="$TEST_ROOT/mode-probe"
mkdir -p "$PROBE"
chmod 700 "$PROBE"
if [ "$(mode_of "$PROBE")" = "700" ]; then
    [ "$(mode_of "$STORE")" = "700" ] ||
        fail "the account store should not be readable by other users"
    [ "$(mode_of "$STORE/beta/credentials.json")" = "600" ] ||
        fail "saved credentials should not be readable by other users"
else
    echo "  (skipped the permission checks: this filesystem does not keep POSIX modes)"
fi

echo "PASS: claude"
