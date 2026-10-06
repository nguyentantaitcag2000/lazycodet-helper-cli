#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../lazy.sh"
NOTIFY_SCRIPT="${SCRIPT_DIR}/../lib/agent-notify.mjs"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-agent-notify.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-agent-notify.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
assert_has() { grep -qF -- "$2" <<<"$1" || fail "expected output to contain: $2"; }
assert_lacks() {
    if grep -qF -- "$2" <<<"$1"; then
        fail "expected output to omit: $2"
    fi
}

FAKE_BIN="$TEST_ROOT/bin"
FAKE_PS_LOG="$TEST_ROOT/powershell.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/powershell.exe" <<'FAKEPS'
#!/bin/bash
printf '%s\n' "$*" >> "$POWERSHELL_LOG"
encoded="${!#}"
node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64").toString("utf16le"))' \
    "$encoded" >> "$POWERSHELL_LOG"
printf '\n' >> "$POWERSHELL_LOG"
echo 'Microsoft Zira Desktop'
FAKEPS
cat > "$FAKE_BIN/cmd.exe" <<'FAKECMD'
#!/bin/bash
exit 0
FAKECMD
chmod +x "$FAKE_BIN/powershell.exe" "$FAKE_BIN/cmd.exe"

run_notify() {
    HOME="$FAKE_HOME" POWERSHELL_LOG="$FAKE_PS_LOG" \
        LAZY_AGENT_NOTIFY_POWERSHELL="$FAKE_BIN/powershell.exe" \
        node "$NOTIFY_SCRIPT" "$@"
}

FAKE_HOME="$TEST_ROOT/home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.codex"
cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Read"] },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "echo existing-claude-hook" }
        ]
      }
    ]
  }
}
JSON
cat > "$FAKE_HOME/.codex/hooks.json" <<'JSON'
{
  "description": "Keep this description.",
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "echo existing-codex-hook" }
        ]
      }
    ]
  }
}
JSON

echo '== install and preserve unrelated settings =='
OUT="$(run_notify)"
assert_has "$OUT" 'Installed global completion announcements'
assert_has "$OUT" 'Microsoft Zira Desktop'
[ -x "$FAKE_HOME/.local/share/lazy/agent-notify/agent-notify.mjs" ] || fail 'runtime was not installed'
node -e '
const fs = require("fs");
const home = process.argv[1];
const claude = JSON.parse(fs.readFileSync(`${home}/.claude/settings.json`));
const codex = JSON.parse(fs.readFileSync(`${home}/.codex/hooks.json`));
if (claude.permissions.allow[0] !== "Read") process.exit(1);
if (!JSON.stringify(claude).includes("existing-claude-hook")) process.exit(2);
if (!JSON.stringify(codex).includes("existing-codex-hook")) process.exit(3);
if (!JSON.stringify(codex).includes("Keep this description.")) process.exit(4);
' "$FAKE_HOME" || fail 'install changed unrelated configuration'

echo '== reinstall is idempotent =='
run_notify >/dev/null
node -e '
const fs = require("fs");
const home = process.argv[1];
for (const [provider, file] of [["claude", ".claude/settings.json"], ["codex", ".codex/hooks.json"]]) {
  const config = JSON.parse(fs.readFileSync(`${home}/${file}`));
  const handlers = (config.hooks.Stop || []).flatMap(group => group.hooks || []);
  const managed = handlers.filter(h => h.command === `node "$HOME/.local/share/lazy/agent-notify/agent-notify.mjs" --hook ${provider}`);
  if (managed.length !== 1) process.exit(1);
}
' "$FAKE_HOME" || fail 'reinstall duplicated a managed hook'
run_notify --check >/dev/null || fail '--check rejected a healthy installation'

echo '== hook reads an English completion summary =='
: > "$FAKE_PS_LOG"
HOOK="$FAKE_HOME/.local/share/lazy/agent-notify/agent-notify.mjs"
OUT="$(printf '%s' '{"last_assistant_message":"Implemented the notification hook. Tests pass."}' | \
    HOME="$FAKE_HOME" POWERSHELL_LOG="$FAKE_PS_LOG" \
    LAZY_AGENT_NOTIFY_POWERSHELL="$FAKE_BIN/powershell.exe" node "$HOOK" --hook codex)"
[ "$OUT" = '{}' ] || fail 'Codex Stop hook did not return JSON'
grep -qF 'Codex has finished. Implemented the notification hook.' "$FAKE_PS_LOG" || \
    fail 'hook did not pass the concise completion summary to Windows TTS'

echo '== hook uses an English fallback for Vietnamese output =='
: > "$FAKE_PS_LOG"
printf '%s' '{"last_assistant_message":"Đã hoàn tất tính năng thông báo."}' | \
    HOME="$FAKE_HOME" POWERSHELL_LOG="$FAKE_PS_LOG" \
    LAZY_AGENT_NOTIFY_POWERSHELL="$FAKE_BIN/powershell.exe" node "$HOOK" --hook claude >/dev/null
grep -qF 'Claude has finished the task.' "$FAKE_PS_LOG" || fail 'Vietnamese output did not use the English fallback'
assert_lacks "$(cat "$FAKE_PS_LOG")" 'Đã hoàn tất'

echo '== background work does not announce early =='
: > "$FAKE_PS_LOG"
printf '%s' '{"last_assistant_message":"Paused.","background_tasks":[{"id":"job"}]}' | \
    HOME="$FAKE_HOME" POWERSHELL_LOG="$FAKE_PS_LOG" \
    LAZY_AGENT_NOTIFY_POWERSHELL="$FAKE_BIN/powershell.exe" node "$HOOK" --hook claude >/dev/null
[ ! -s "$FAKE_PS_LOG" ] || fail 'hook announced while a background task was active'

echo '== test speech =='
OUT="$(run_notify --test)"
assert_has "$OUT" 'Spoke the test sentence'

echo '== uninstall preserves unrelated settings =='
OUT="$(run_notify --uninstall)"
assert_has "$OUT" 'Unrelated settings and hooks were preserved'
[ ! -e "$HOOK" ] || fail 'runtime remains after uninstall'
grep -qF 'existing-claude-hook' "$FAKE_HOME/.claude/settings.json" || fail 'Claude hook was lost'
grep -qF 'existing-codex-hook' "$FAKE_HOME/.codex/hooks.json" || fail 'Codex hook was lost'
if grep -qF 'agent-notify.mjs' "$FAKE_HOME/.claude/settings.json" "$FAKE_HOME/.codex/hooks.json"; then
    fail 'managed hook remains after uninstall'
fi

echo '== files created by the installer are removed =='
SECOND_HOME="$TEST_ROOT/second-home"
mkdir -p "$SECOND_HOME"
HOME="$SECOND_HOME" POWERSHELL_LOG="$FAKE_PS_LOG" \
    LAZY_AGENT_NOTIFY_POWERSHELL="$FAKE_BIN/powershell.exe" node "$NOTIFY_SCRIPT" >/dev/null
HOME="$SECOND_HOME" node "$NOTIFY_SCRIPT" --uninstall >/dev/null
[ ! -e "$SECOND_HOME/.claude/settings.json" ] || fail 'installer-created Claude config remains'
[ ! -e "$SECOND_HOME/.codex/hooks.json" ] || fail 'installer-created Codex config remains'

echo '== malformed config fails without overwriting it =='
BAD_HOME="$TEST_ROOT/bad-home"
mkdir -p "$BAD_HOME/.claude"
printf '%s\n' '{ invalid json' > "$BAD_HOME/.claude/settings.json"
if HOME="$BAD_HOME" POWERSHELL_LOG="$FAKE_PS_LOG" \
    LAZY_AGENT_NOTIFY_POWERSHELL="$FAKE_BIN/powershell.exe" node "$NOTIFY_SCRIPT" >/dev/null 2>&1; then
    fail 'installer accepted malformed JSON'
fi
grep -qxF '{ invalid json' "$BAD_HOME/.claude/settings.json" || fail 'malformed config was overwritten'
[ ! -e "$BAD_HOME/.local/share/lazy/agent-notify/agent-notify.mjs" ] || fail 'runtime installed after validation failed'

echo '== CLI exposes help on WSL =='
OUT="$(HOME="$FAKE_HOME" WSL_DISTRO_NAME=Test MSYSTEM= PATH="$FAKE_BIN:$PATH" \
    bash "$CLI" agent.notify --help)"
assert_has "$OUT" 'lazy agent.notify --uninstall'

echo 'agent.notify tests passed'
