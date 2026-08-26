#!/bin/bash
# Copy the Claude Code login from the Windows host into a WSL distro.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

usage() {
    echo "Usage:"
    echo "  lazy claude.auth [distro] [-u <user>] [-y]"
    echo "  lazy claude.auth --list"
    echo "  lazy claude.auth [distro] --check"
    echo ""
    echo "Copies the Claude Code login (~/.claude/.credentials.json) from the Windows"
    echo "host into a WSL distro, so 'claude' in there is already signed in."
    echo ""
    echo "Options:"
    echo "  -u, --user <name>  Target this Linux user instead of the distro default"
    echo "  -y, --yes          Skip the confirmation prompt"
    echo "      --list         List the WSL distros and exit"
    echo "      --check        Report both sides, write nothing"
    echo "  -h, --help         Show this help"
}

DISTRO=""
WSL_USER=""
ASSUME_YES=0
DO_LIST=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --list) DO_LIST=1 ;;
        --check) CHECK_ONLY=1 ;;
        -u|--user)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --user needs a name"
                exit 1
            fi
            WSL_USER="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1"; echo ""; usage; exit 1 ;;
        *)
            if [ -n "$DISTRO" ]; then
                echo "Error: Only one distro is supported."
                exit 1
            fi
            DISTRO="$1"
            ;;
    esac
    shift
done

c_bold=""; c_dim=""; c_ok=""; c_warn=""; c_err=""; c_reset=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_ok=$'\033[32m'
    c_warn=$'\033[33m'; c_err=$'\033[31m'; c_reset=$'\033[0m'
fi

say_ok()   { printf '  %s%s%s\n' "$c_ok" "$1" "$c_reset"; }
say_warn() { printf '  %s%s%s\n' "$c_warn" "$1" "$c_reset"; }
say_dim()  { printf '  %s%s%s\n' "$c_dim" "$1" "$c_reset"; }
say_err()  { printf '%sError: %s%s\n' "$c_err" "$1" "$c_reset" >&2; }

# ----------------------------------------------------------------- host side

# Where Claude Code keeps its config. CLAUDE_CONFIG_DIR wins when it is set.
HOST_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
HOST_CRED="${HOST_DIR}/.credentials.json"
HOST_CONFIG="${HOME}/.claude.json"

# A credentials file is only useful if accessToken actually holds something.
# An empty string is what a logout leaves behind, and on disk that looks
# exactly like a real login until you read the value.
cred_has_token() {
    grep -qE '"accessToken"[[:space:]]*:[[:space:]]*"[^"]' "$1" 2>/dev/null
}

cred_expiry() {
    local ms
    ms="$(grep -oE '"expiresAt"[[:space:]]*:[[:space:]]*[0-9]+' "$1" 2>/dev/null |
          grep -oE '[0-9]+$' | head -1)"
    [ -n "$ms" ] || return 1
    date -d "@$((ms / 1000))" '+%Y-%m-%d %H:%M' 2>/dev/null
}

check_host_credentials() {
    if [ ! -f "$HOST_CRED" ]; then
        say_err "No Claude Code login on this host -> ${HOST_CRED}"
        echo "Run 'claude' on Windows and sign in first." >&2
        return 1
    fi

    if ! cred_has_token "$HOST_CRED"; then
        say_err "Host credentials hold no token -> ${HOST_CRED}"
        echo "That is the logged-out state. Run 'claude' on Windows and sign in first." >&2
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------ wsl side

require_wsl() {
    if ! command -v wsl.exe >/dev/null 2>&1; then
        say_err "wsl.exe not found - WSL does not look installed on this host."
        return 1
    fi
    return 0
}

# wsl.exe writes UTF-16LE unless the build honors WSL_UTF8, so decode by hand
# when the output still carries NUL bytes. The detection goes through a file
# because command substitution drops NUL bytes (with a warning) before we could
# ever look at them.
list_distros() {
    local tmp
    local raw

    tmp="$(mktemp "${TMPDIR:-/tmp}/lazy-wsl-list.XXXXXX")" || return 1
    WSL_UTF8=1 wsl.exe -l -q > "$tmp" 2>/dev/null

    if LC_ALL=C tr -d '\000' < "$tmp" | cmp -s - "$tmp"; then
        raw="$(cat "$tmp")"
    else
        raw="$(iconv -f UTF-16LE -t UTF-8 < "$tmp" 2>/dev/null || tr -d '\000' < "$tmp")"
    fi

    rm -f "$tmp"
    printf '%s\n' "$raw" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

# WSL matches distro names case-insensitively; echo back the canonical spelling
# so every later message and wsl.exe call uses the real name.
resolve_distro() {
    local want
    local line
    want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" = "$want" ]; then
            printf '%s' "$line"
            return 0
        fi
    done <<< "$(list_distros)"

    return 1
}

prompt_for_distro() {
    local distros=()
    local line
    local i=1
    local answer
    local resolved

    while IFS= read -r line; do
        [ -n "$line" ] && distros+=("$line")
    done <<< "$(list_distros)"

    if [ "${#distros[@]}" -eq 0 ]; then
        say_err "No WSL distros found."
        return 1
    fi

    if [ ! -t 0 ]; then
        say_err "No distro given and no terminal to ask on."
        echo "Usage: lazy claude.auth <distro>" >&2
        return 1
    fi

    printf '%sWSL distros:%s\n' "$c_bold" "$c_reset" >&2
    for line in "${distros[@]}"; do
        printf '  %2d) %s\n' "$i" "$line" >&2
        i=$((i + 1))
    done
    printf '\n' >&2

    while :; do
        printf 'Distro (number or name): ' >&2
        if ! read -r answer; then
            printf '\n' >&2
            return 1
        fi

        answer="$(printf '%s' "$answer" | tr -d '[:space:]')"
        [ -n "$answer" ] || continue

        if [[ "$answer" =~ ^[0-9]+$ ]] &&
           [ "$answer" -ge 1 ] && [ "$answer" -le "${#distros[@]}" ]; then
            printf '%s' "${distros[$((answer - 1))]}"
            return 0
        fi

        resolved="$(resolve_distro "$answer")"
        if [ -n "$resolved" ]; then
            printf '%s' "$resolved"
            return 0
        fi

        printf '  no such distro -> %s\n' "$answer" >&2
    done
}

# Every wsl.exe call goes through here. MSYS_NO_PATHCONV stops Git Bash from
# rewriting Linux paths in the arguments into C:\ paths, and -u is only passed
# when the caller asked for a specific user.
run_in_distro() {
    local distro="$1"
    shift

    if [ -n "$WSL_USER" ]; then
        MSYS_NO_PATHCONV=1 wsl.exe -d "$distro" -u "$WSL_USER" -- "$@"
    else
        MSYS_NO_PATHCONV=1 wsl.exe -d "$distro" -- "$@"
    fi
}

# Report the distro's Claude state as KEY=VALUE lines. Deliberately avoids
# python and node: a distro installed with the native installer may have neither.
probe_distro() {
    local distro="$1"

    {
        cat <<'REMOTE_PROBE'
set -u
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
echo "USER=$(id -un)"
echo "HOME=$HOME"
echo "DIR=$dir"

cred="$dir/.credentials.json"
if [ -f "$cred" ]; then
    if grep -qE '"accessToken"[[:space:]]*:[[:space:]]*"[^"]' "$cred"; then
        echo "CRED=token"
    else
        echo "CRED=empty"
    fi
    echo "SHA=$(sha256sum < "$cred" | cut -d' ' -f1)"
else
    echo "CRED=missing"
fi

if command -v claude >/dev/null 2>&1; then
    echo "CLI=$(command -v claude)"
elif [ -x "$HOME/.local/bin/claude" ]; then
    echo "CLI=$HOME/.local/bin/claude"
else
    echo "CLI=missing"
fi
REMOTE_PROBE
    } | run_in_distro "$distro" bash -s 2>/dev/null | tr -d '\r'
}

probe_value() {
    printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-
}

# ------------------------------------------------------------------- install

# The credentials travel as base64 on stdin rather than as arguments: nothing
# secret shows up in the distro's process list, and no CRLF translation can
# corrupt the payload on the way in.
push_credentials() {
    local distro="$1"
    local cred_b64="$2"
    local cfg_b64="$3"

    {
        printf "CRED_B64='%s'\n" "$cred_b64"
        printf "CFG_B64='%s'\n" "$cfg_b64"
        cat <<'REMOTE_PUSH'
set -eu
umask 077

dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$dir"
cred="$dir/.credentials.json"

if [ -s "$cred" ]; then
    cp -p "$cred" "${cred}.lazy.bak"
    echo "BACKUP=${cred}.lazy.bak"
fi

printf '%s' "$CRED_B64" | base64 -d > "${cred}.lazy.tmp"
chmod 600 "${cred}.lazy.tmp"
mv -f "${cred}.lazy.tmp" "$cred"
echo "WROTE=$cred"
echo "SHA=$(sha256sum < "$cred" | cut -d' ' -f1)"

# The token alone still lands you on the login/onboarding screen: Claude Code
# also reads oauthAccount and hasCompletedOnboarding from ~/.claude.json. Merge
# just those keys - the rest of the host file is Windows-specific history.
config="$HOME/.claude.json"
if [ -z "$CFG_B64" ]; then
    echo "MERGE=skipped-no-host-config"
    exit 0
fi

merge_with_python() {
    printf '%s' "$CFG_B64" | base64 -d | python3 -c '
import json, os, sys

target = sys.argv[1]
host = json.load(sys.stdin)

try:
    with open(target) as fh:
        cur = json.load(fh)
except Exception:
    cur = {}

if not isinstance(cur, dict):
    cur = {}

if "oauthAccount" in host:
    cur["oauthAccount"] = host["oauthAccount"]
cur["hasCompletedOnboarding"] = True
for key in ("lastOnboardingVersion", "userID"):
    if key in host and key not in cur:
        cur[key] = host[key]

tmp = target + ".lazy.tmp"
with open(tmp, "w") as fh:
    json.dump(cur, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, target)
' "$config"
}

merge_with_node() {
    printf '%s' "$CFG_B64" | base64 -d | node -e '
const fs = require("fs");
const target = process.argv[1];
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", c => { raw += c; });
process.stdin.on("end", () => {
  const host = JSON.parse(raw);
  let cur = {};
  try { cur = JSON.parse(fs.readFileSync(target, "utf8")); } catch (e) { cur = {}; }
  if (!cur || typeof cur !== "object" || Array.isArray(cur)) cur = {};
  if (host.oauthAccount) cur.oauthAccount = host.oauthAccount;
  cur.hasCompletedOnboarding = true;
  for (const k of ["lastOnboardingVersion", "userID"]) {
    if (k in host && !(k in cur)) cur[k] = host[k];
  }
  const tmp = target + ".lazy.tmp";
  fs.writeFileSync(tmp, JSON.stringify(cur, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, target);
});
' "$config"
}

if [ -s "$config" ]; then
    cp -p "$config" "${config}.lazy.bak"
    echo "CONFIG_BACKUP=${config}.lazy.bak"
fi

if command -v python3 >/dev/null 2>&1 && merge_with_python; then
    echo "MERGE=python3"
elif command -v node >/dev/null 2>&1 && merge_with_node; then
    echo "MERGE=node"
else
    rm -f "${config}.lazy.tmp"
    echo "MERGE=skipped-no-json-tool"
fi
REMOTE_PUSH
    } | run_in_distro "$distro" bash -s 2>&1 | tr -d '\r'
}

# ---------------------------------------------------------------------- main

if ! is_git_bash; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
        say_err "You are already inside WSL."
        echo "Run this from Git Bash on the Windows host - that is where the login lives:" >&2
        echo "  lazy claude.auth ${DISTRO:-<distro>}" >&2
    else
        say_err "This copies a Windows login into WSL, so it only runs on Windows (Git Bash)."
    fi
    exit 1
fi

require_wsl || exit 1

if [ "$DO_LIST" -eq 1 ]; then
    DISTROS="$(list_distros)"
    if [ -z "$DISTROS" ]; then
        echo "No WSL distros found."
        exit 1
    fi
    printf '%sWSL distros:%s\n' "$c_bold" "$c_reset"
    printf '%s\n' "$DISTROS" | sed 's/^/  /'
    exit 0
fi

printf '%sHost (Windows):%s\n' "$c_bold" "$c_reset"
say_dim "$HOST_CRED"

if [ -f "$HOST_CRED" ] && cred_has_token "$HOST_CRED"; then
    HOST_EXPIRY="$(cred_expiry "$HOST_CRED" || true)"
    if [ -n "$HOST_EXPIRY" ]; then
        say_ok "signed in (access token valid until ${HOST_EXPIRY})"
    else
        say_ok "signed in"
    fi
elif [ -f "$HOST_CRED" ]; then
    say_warn "credentials file present but no token (logged out)"
else
    say_warn "no credentials file"
fi
echo ""

if [ -z "$DISTRO" ]; then
    DISTRO="$(prompt_for_distro)" || exit 1
    echo ""
fi

CANONICAL="$(resolve_distro "$DISTRO")"
if [ -z "$CANONICAL" ]; then
    say_err "No such WSL distro -> ${DISTRO}"
    echo "" >&2
    echo "Available:" >&2
    list_distros | sed 's/^/  /' >&2
    exit 1
fi
DISTRO="$CANONICAL"

printf '%sDistro %s:%s\n' "$c_bold" "$DISTRO" "$c_reset"
PROBE="$(probe_distro "$DISTRO")"
if [ -z "$PROBE" ]; then
    say_err "Could not run a shell in ${DISTRO}."
    exit 1
fi

D_USER="$(probe_value "$PROBE" USER)"
D_DIR="$(probe_value "$PROBE" DIR)"
D_CRED="$(probe_value "$PROBE" CRED)"
D_SHA="$(probe_value "$PROBE" SHA)"
D_CLI="$(probe_value "$PROBE" CLI)"

say_dim "user: ${D_USER}   config: ${D_DIR}"

case "$D_CRED" in
    token)   say_ok "already signed in" ;;
    empty)   say_warn "credentials file present but no token (logged out)" ;;
    missing) say_warn "no credentials file" ;;
esac

if [ "$D_CLI" = "missing" ]; then
    say_warn "claude CLI not found here - the login is copied anyway, install it later"
else
    say_dim "cli:  ${D_CLI}"
fi
echo ""

HOST_SHA=""
if [ -f "$HOST_CRED" ]; then
    HOST_SHA="$(sha256sum < "$HOST_CRED" | cut -d' ' -f1)"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -n "$D_SHA" ] && [ "$D_SHA" = "$HOST_SHA" ]; then
        echo "Both sides hold the same login - nothing to copy."
    else
        echo "Run 'lazy claude.auth ${DISTRO}' to copy the host login over."
    fi
    exit 0
fi

check_host_credentials || exit 1

if [ "$D_CRED" = "token" ] && [ "$D_SHA" = "$HOST_SHA" ]; then
    echo "${DISTRO} already holds this exact login - nothing to do."
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        say_err "Refusing to overwrite credentials without confirmation (no terminal). Use -y."
        exit 1
    fi
    printf 'Copy this login into %s (%s)? [y/N] ' "$DISTRO" "${D_DIR}/.credentials.json"
    read -r REPLY_YN
    case "$REPLY_YN" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
    echo ""
fi

CRED_B64="$(base64 -w0 < "$HOST_CRED")"
CFG_B64=""
if [ -s "$HOST_CONFIG" ]; then
    CFG_B64="$(base64 -w0 < "$HOST_CONFIG")"
fi

RESULT="$(push_credentials "$DISTRO" "$CRED_B64" "$CFG_B64")"
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
    say_err "Copy failed."
    printf '%s\n' "$RESULT" | sed 's/^/  /' >&2
    exit 1
fi

NEW_SHA="$(probe_value "$RESULT" SHA)"
BACKUP="$(probe_value "$RESULT" BACKUP)"
CFG_BACKUP="$(probe_value "$RESULT" CONFIG_BACKUP)"
MERGE="$(probe_value "$RESULT" MERGE)"

if [ "$NEW_SHA" != "$HOST_SHA" ]; then
    say_err "The copy landed but does not match the host file."
    printf '%s\n' "$RESULT" | sed 's/^/  /' >&2
    exit 1
fi

say_ok "credentials copied and verified (sha256 matches)"

case "$MERGE" in
    python3|node)
        say_ok "account + onboarding flags merged into ~/.claude.json" ;;
    skipped-no-json-tool)
        say_warn "no python3 or node in ${DISTRO}: ~/.claude.json untouched, claude may run onboarding once" ;;
    skipped-no-host-config)
        say_warn "no ~/.claude.json on the host to merge from" ;;
esac

[ -n "$BACKUP" ] && say_dim "previous credentials: ${BACKUP}"
[ -n "$CFG_BACKUP" ] && say_dim "previous config:      ${CFG_BACKUP}"

echo ""
echo "Done. Try it:"
echo "  wsl -d ${DISTRO}"
echo "  claude"
