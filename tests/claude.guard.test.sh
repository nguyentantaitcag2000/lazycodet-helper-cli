#!/bin/bash
#
# Every test here runs against a throwaway HOME and a stub "Claude Code"
# executable that only echoes. Nothing in this file can start the real Claude
# Code: the guard is pointed at the stub through PATH and --bin, and the real
# binary is never on the PATH these tests build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${SCRIPT_DIR}/../commands/claude.guard.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-claude-guard.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-claude-guard.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }

assert_has() {
    printf '%s\n' "$1" | grep -qF -- "$2" || fail "expected output to contain: $2"
}
assert_lacks() {
    if printf '%s\n' "$1" | grep -qF -- "$2"; then
        fail "expected output to omit: $2"
    fi
}

# --- Sandbox -----------------------------------------------------------------

FAKE_HOME="$TEST_ROOT/home"
STUB_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_HOME" "$STUB_BIN"

# Stands in for the real Claude Code executable. It must be something the guard
# can exec, so the allowed path can be proved end to end without Claude Code.
cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/bash
echo "STUB-CLAUDE-STARTED args=$*"
STUB
chmod +x "$STUB_BIN/claude"

GUARD_DIR="$FAKE_HOME/.local/bin-guard"
RC="$FAKE_HOME/.bashrc"
FLAG="$FAKE_HOME/.claude/claude-code-disabled"

# A repo whose origin uses a per-account SSH alias, like the real setup.
COMPANY="$TEST_ROOT/company-repo"
git init -q "$COMPANY"
git -C "$COMPANY" remote add origin "git@github.com-work:acme-ltd/billing.git"

PERSONAL="$TEST_ROOT/personal-repo"
git init -q "$PERSONAL"
git -C "$PERSONAL" remote add origin "git@github.com:someone/side-project.git"

NOORIGIN="$TEST_ROOT/no-origin"
git init -q "$NOORIGIN"

PLAIN="$TEST_ROOT/plain-dir"
mkdir -p "$PLAIN"

mkdir -p "$FAKE_HOME/.ssh"
cat > "$FAKE_HOME/.ssh/config" <<'SSHCFG'
Host github.com-work
    HostName github.com
    User git
SSHCFG

# PATH deliberately excludes anywhere the real Claude Code could live.
run_guard() {
    local dir="$1"; shift
    ( cd "$dir" && HOME="$FAKE_HOME" SHELL=/bin/bash \
        PATH="$STUB_BIN:/usr/bin:/bin" NO_COLOR=1 \
        bash "$CMD" "$@" 2>&1 )
}

# Runs an installed guard script the way a shell would, with the guard dir
# first on PATH.
run_installed() {
    local dir="$1" prog="$2"; shift 2
    ( cd "$dir" && HOME="$FAKE_HOME" \
        PATH="$GUARD_DIR:$STUB_BIN:/usr/bin:/bin" NO_COLOR=1 \
        bash "$GUARD_DIR/$prog" "$@" 2>&1 )
}

echo "== check on a clean machine =="
OUT="$(run_guard "$COMPANY" --check || true)"
assert_has "$OUT" "github.com-work/acme-ltd/*"
assert_has "$OUT" "github.com/acme-ltd/*"
assert_has "$OUT" "SSH alias"
assert_has "$OUT" "Run without --check to apply."
[ ! -e "$GUARD_DIR/claude" ] || fail "--check must not install anything"
ok "--check reports the derived allowlist and writes nothing"

echo "== refuses outside a repository, with no patterns to go on =="
OUT="$(run_guard "$PLAIN" --check 2>&1 || true)"
assert_has "$OUT" "Cannot work out which repositories to allow"
ok "stops when there is no origin to derive from"

OUT="$(run_guard "$PLAIN" --check --allow 'github.com/acme-ltd/*' || true)"
assert_has "$OUT" "github.com/acme-ltd/*"
ok "--allow works without a repository"

echo "== install =="
OUT="$(run_guard "$COMPANY" -y)"
assert_has "$OUT" "Verified: this repository is allowed"
assert_has "$OUT" "Done."
for f in claude claude-run claude-reblock claude-unblock claude-guard-common.sh; do
    [ -f "$GUARD_DIR/$f" ] || fail "missing installed file: $f"
done
[ -x "$GUARD_DIR/claude" ] || fail "shim is not executable"
grep -qF '>>> lazy claude.guard >>>' "$RC" || fail "rc block missing"
grep -qF 'bin-guard' "$RC" || fail "rc block does not add the guard dir to PATH"
ok "installs the scripts and wires the startup file"

echo "== generated allowlist logic =="
check_allow() {
    ( HOME="$FAKE_HOME"; . "$GUARD_DIR/claude-guard-common.sh" && cg_is_allowed "$1" >/dev/null )
}
check_allow 'git@github.com-work:acme-ltd/billing.git'    || fail "company remote must be allowed"
check_allow 'https://github.com/acme-ltd/other-repo.git'  || fail "same org over https must be allowed"
check_allow 'git@github.com:acme-ltd/anything'            || fail "alias base host must be allowed"
! check_allow 'git@github.com:someone/side-project.git'   || fail "other org must be rejected"
! check_allow 'git@github.com:acme-ltd-evil/repo.git'     || fail "lookalike org must be rejected"
! check_allow 'https://github.com.evil.com/acme-ltd/r.git' || fail "lookalike host must be rejected"
! check_allow 'git@gitlab.com:acme-ltd/repo.git'          || fail "other provider must be rejected"
! check_allow '/srv/local/repo'                           || fail "local path must be rejected"
ok "allowlist accepts the organisation and rejects lookalikes"

echo "== shim, kill switch off =="
OUT="$(run_installed "$COMPANY" claude --hello)"
assert_has "$OUT" "STUB-CLAUDE-STARTED args=--hello"
ok "allowed repository reaches the executable with its arguments intact"

OUT="$(run_installed "$PERSONAL" claude || true)"
assert_has "$OUT" "CLAUDE CODE BLOCKED"
assert_has "$OUT" "not on the allowlist"
assert_lacks "$OUT" "STUB-CLAUDE-STARTED"
ok "other people's repository is blocked"

OUT="$(run_installed "$NOORIGIN" claude || true)"
assert_has "$OUT" "no 'origin' remote"
assert_lacks "$OUT" "STUB-CLAUDE-STARTED"
ok "repository without an origin is blocked"

OUT="$(run_installed "$PLAIN" claude || true)"
assert_has "$OUT" "Not inside a git repository"
assert_lacks "$OUT" "STUB-CLAUDE-STARTED"
ok "non-Git directory is blocked"

echo "== kill switch =="
run_installed "$COMPANY" claude-reblock >/dev/null
[ -e "$FLAG" ] || fail "flag was not created"
[ ! -x "$STUB_BIN/claude" ] || fail "executable bit should be gone"
ok "claude-reblock arms it and drops the execute bit"

OUT="$(run_installed "$COMPANY" claude || true)"
assert_has "$OUT" "CLAUDE CODE DISABLED"
assert_lacks "$OUT" "STUB-CLAUDE-STARTED"
ok "armed kill switch blocks even an allowlisted repository"

OUT="$(cd "$COMPANY" && HOME="$FAKE_HOME" PATH="/usr/bin:/bin" NO_COLOR=1 "$STUB_BIN/claude" 2>&1 || true)"
assert_lacks "$OUT" "STUB-CLAUDE-STARTED"
ok "absolute path is refused too"

echo "== claude-run =="
OUT="$(run_installed "$COMPANY" claude-run --resume)"
assert_has "$OUT" "STUB-CLAUDE-STARTED args=--resume"
assert_has "$OUT" "kill switch re-armed"
[ "$(printf '%s\n' "$OUT" | grep -c 'kill switch re-armed')" -eq 1 ] \
    || fail "the re-arm message must be printed exactly once"
[ ! -x "$STUB_BIN/claude" ] || fail "claude-run must re-lock on exit"
[ -e "$FLAG" ] || fail "claude-run must not clear the flag"
ok "runs one session, re-arms once, leaves the switch armed"

OUT="$(run_installed "$PERSONAL" claude-run || true)"
assert_has "$OUT" "not on the allowlist"
assert_lacks "$OUT" "STUB-CLAUDE-STARTED"
[ ! -x "$STUB_BIN/claude" ] || fail "a blocked claude-run must not unlock anything"
ok "claude-run still honours the allowlist and never unlocks for it"

echo "== self-heal after a hard kill =="
chmod u+x "$STUB_BIN/claude"                     # as a SIGKILLed session would leave it
mkdir -p "$FAKE_HOME/.claude/claude-run-leases"
: > "$FAKE_HOME/.claude/claude-run-leases/999999"  # a lease whose process is gone
run_installed "$COMPANY" claude-reblock -q >/dev/null
[ ! -x "$STUB_BIN/claude" ] || fail "quiet re-assert should have re-locked"
[ ! -e "$FAKE_HOME/.claude/claude-run-leases/999999" ] || fail "stale lease should be pruned"
ok "claude-reblock -q recovers from a killed session"

sleep 120 &
LIVE=$!
chmod u+x "$STUB_BIN/claude"
: > "$FAKE_HOME/.claude/claude-run-leases/$LIVE"
run_installed "$COMPANY" claude-reblock -q >/dev/null
[ -x "$STUB_BIN/claude" ] || fail "must not re-lock under a live session"
kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
rm -f "$FAKE_HOME/.claude/claude-run-leases/$LIVE"
ok "a live session is not re-locked out from under"

echo "== claude-unblock =="
run_installed "$COMPANY" claude-unblock >/dev/null
[ ! -e "$FLAG" ] || fail "flag should be gone"
[ -x "$STUB_BIN/claude" ] || fail "executable bit should be back"
OUT="$(run_installed "$COMPANY" claude)"
assert_has "$OUT" "STUB-CLAUDE-STARTED"
OUT="$(run_installed "$PERSONAL" claude || true)"
assert_has "$OUT" "not on the allowlist"
ok "unblock restores running, and the allowlist still applies"

echo "== idempotence =="
BEFORE="$(grep -c '>>> lazy claude.guard >>>' "$RC")"
run_guard "$COMPANY" -y >/dev/null
AFTER="$(grep -c '>>> lazy claude.guard >>>' "$RC")"
[ "$BEFORE" -eq 1 ] && [ "$AFTER" -eq 1 ] || fail "re-running must not duplicate the rc block"
OUT="$(run_guard "$COMPANY" --check)"
assert_has "$OUT" "The guard is installed."
ok "re-running is idempotent and --check reports installed"

echo "== --exact =="
run_guard "$COMPANY" -y --exact >/dev/null
check_allow 'git@github.com-work:acme-ltd/billing.git' || fail "the repo itself must stay allowed"
! check_allow 'git@github.com-work:acme-ltd/other.git' || fail "--exact must not allow siblings"
ok "--exact pins the allowlist to this repository"

echo "== migrating from a hand-rolled guard =="
# The hand-rolled version this command replaces used its own rc markers and put
# its scripts in ~/.local/bin. Left behind, the old block would prepend the
# guard directory to PATH twice and call a claude-reblock that has just been
# deleted.
run_guard "$COMPANY" -y --uninstall >/dev/null
mkdir -p "$FAKE_HOME/.local/bin"
for f in claude-guard claude-guard-allowlist.sh claude-run claude-reblock claude-unblock; do
    printf '#!/bin/bash\necho old\n' > "$FAKE_HOME/.local/bin/$f"
done
cat >> "$RC" <<'OLDBLOCK'

# >>> claude-code repository guard >>>
export PATH="$HOME/.local/bin-guard:$PATH"
unset -f claude 2>/dev/null
# <<< claude-code repository guard <<<
OLDBLOCK

OUT="$(run_guard "$COMPANY" --check || true)"
assert_has "$OUT" "Older hand-installed copies found"
assert_has "$OUT" "remove the superseded guard block"
ok "--check spots the hand-rolled install"

run_guard "$COMPANY" -y >/dev/null
for f in claude-guard claude-guard-allowlist.sh claude-run claude-reblock claude-unblock; do
    [ ! -e "$FAKE_HOME/.local/bin/$f" ] || fail "superseded $f should have been removed"
done
grep -qF '>>> claude-code repository guard >>>' "$RC" && fail "the old rc block should be gone"
[ "$(grep -c '>>> lazy claude.guard >>>' "$RC")" -eq 1 ] || fail "exactly one new rc block expected"
ok "migration removes the old scripts and the old rc block"

echo "== Windows-side Claude Code (WSL only) =="
# On WSL a Windows install is reachable as claude.exe and /mnt/c has no real
# execute bit, so shadowing the name is the only thing this side can do. On
# every other platform nothing should be created.
cat > "$STUB_BIN/claude.exe" <<'WINSTUB'
#!/bin/bash
echo "WINDOWS-STUB-STARTED"
WINSTUB
chmod +x "$STUB_BIN/claude.exe"
run_guard "$COMPANY" -y >/dev/null
if [ "$(uname -s)" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then
    [ -L "$GUARD_DIR/claude.exe" ] || fail "WSL should shadow claude.exe"
    OUT="$(run_installed "$PERSONAL" claude.exe || true)"
    assert_has "$OUT" "CLAUDE CODE BLOCKED"
    assert_lacks "$OUT" "WINDOWS-STUB-STARTED"
    ok "WSL shadows claude.exe and guards it"
else
    [ ! -e "$GUARD_DIR/claude.exe" ] || fail "only WSL should create the claude.exe shadow"
    ok "no claude.exe shadow outside WSL"
fi
rm -f "$STUB_BIN/claude.exe"

echo "== uninstall =="
run_guard "$COMPANY" -y --arm >/dev/null
[ -e "$FLAG" ] || fail "--arm should have armed it"
[ ! -x "$STUB_BIN/claude" ] || fail "--arm should have dropped the execute bit"
OUT="$(run_guard "$COMPANY" -y --uninstall)"
assert_has "$OUT" "Done."
[ -x "$STUB_BIN/claude" ] || fail "uninstall must restore the execute bit"
[ ! -e "$FLAG" ] || fail "uninstall must clear the flag"
[ ! -e "$GUARD_DIR/claude" ] || fail "uninstall must remove the shim"
grep -qF '>>> lazy claude.guard >>>' "$RC" && fail "uninstall must remove the rc block"
ok "--uninstall restores the machine and leaves no execute bit behind"

echo ""
echo "All $PASS checks passed."
