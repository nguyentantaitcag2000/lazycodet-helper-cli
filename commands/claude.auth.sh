#!/bin/bash
# Sync the Claude Code login between the Windows host and a WSL distro,
# in whichever direction still holds a valid login.

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
    echo "Syncs the Claude Code login (~/.claude/.credentials.json) between the Windows"
    echo "host and a WSL distro. The direction is decided by which side is still signed"
    echo "in: a valid host login is pushed into the distro, and when the host token has"
    echo "expired while the distro's is still good, it is pulled back the other way."
    echo ""
    echo "Options:"
    echo "      --push         Force host -> distro"
    echo "      --pull         Force distro -> host"
    echo "  -u, --user <name>  Target this Linux user instead of the distro default"
    echo "  -y, --yes          Skip the confirmation prompt"
    echo "      --list         List the WSL distros and exit"
    echo "      --check        Report both sides and the direction, write nothing"
    echo "  -h, --help         Show this help"
}

DISTRO=""
WSL_USER=""
ASSUME_YES=0
DO_LIST=0
CHECK_ONLY=0
FORCED=""

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --list) DO_LIST=1 ;;
        --check) CHECK_ONLY=1 ;;
        --push|--pull)
            if [ -n "$FORCED" ] && [ "$FORCED" != "${1#--}" ]; then
                echo "Error: --push and --pull are opposites; pick one."
                exit 1
            fi
            FORCED="${1#--}"
            ;;
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

NOW_MS="$(( $(date +%s) * 1000 ))"

# --------------------------------------------------------------- credentials

# A credentials file is only useful if accessToken actually holds something.
# An empty string is what a logout leaves behind, and on disk that looks
# exactly like a real login until you read the value.
cred_has_token() {
    grep -qE '"accessToken"[[:space:]]*:[[:space:]]*"[^"]' "$1" 2>/dev/null
}

# expiresAt is milliseconds since the epoch.
cred_expiry_ms() {
    grep -oE '"expiresAt"[[:space:]]*:[[:space:]]*[0-9]+' "$1" 2>/dev/null |
        grep -oE '[0-9]+$' | head -1
}

format_expiry() {
    [ -n "$1" ] || return 1
    date -d "@$(( $1 / 1000 ))" '+%Y-%m-%d %H:%M' 2>/dev/null
}

# Both sides are described with the same four words. Expiry is advisory - Claude
# Code can still refresh an expired access token - but it is the only signal
# available without launching the CLI, and it is what picks the direction.
classify_cred() {
    local kind="$1"
    local expires="$2"

    case "$kind" in
        missing) echo missing; return ;;
        empty)   echo empty;   return ;;
    esac

    if [ -n "$expires" ] && [ "$expires" -le "$NOW_MS" ]; then
        echo expired
    else
        echo valid
    fi
}

state_rank() {
    case "$1" in
        valid)   echo 3 ;;
        expired) echo 2 ;;
        empty)   echo 1 ;;
        *)       echo 0 ;;
    esac
}

report_state() {
    local state="$1"
    local expires="$2"
    local when

    when="$(format_expiry "$expires" || true)"

    case "$state" in
        valid)
            if [ -n "$when" ]; then
                say_ok "signed in (access token valid until ${when})"
            else
                say_ok "signed in"
            fi
            ;;
        expired)
            say_warn "signed in but the access token expired ${when} (a refresh may still work)" ;;
        empty)
            say_warn "credentials file present but no token (logged out)" ;;
        missing)
            say_warn "no credentials file" ;;
    esac
}

# ----------------------------------------------------------------- host side

# Where Claude Code keeps its config. CLAUDE_CONFIG_DIR wins when it is set.
HOST_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
HOST_CRED="${HOST_DIR}/.credentials.json"
HOST_CONFIG="${HOME}/.claude.json"

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
    echo "EXPIRES=$(grep -oE '"expiresAt"[[:space:]]*:[[:space:]]*[0-9]+' "$cred" | grep -oE '[0-9]+$' | head -1)"
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

# ------------------------------------------------------------------ transfer

# The config merge runs on whichever side is being written, so it is written
# once here and both eval'd locally and shipped into the distro on stdin.
merge_snippet() {
    cat <<'MERGE_SNIPPET'
# Reads CFG_B64 from the environment - base64 of the source ~/.claude.json - and
# folds only the account and onboarding keys into the target config. The token
# alone still lands you on the login/onboarding screen: Claude Code also reads
# oauthAccount and hasCompletedOnboarding from ~/.claude.json. The rest of the
# target file - project history, MCP servers, settings - is left as it was.
merge_with_python() {
    printf '%s' "$CFG_B64" | base64 -d | python3 -c '
import json, os, sys

target = sys.argv[1]
src = json.load(sys.stdin)

try:
    with open(target) as fh:
        cur = json.load(fh)
except Exception:
    cur = {}

if not isinstance(cur, dict):
    cur = {}

if "oauthAccount" in src:
    cur["oauthAccount"] = src["oauthAccount"]
cur["hasCompletedOnboarding"] = True
for key in ("lastOnboardingVersion", "userID"):
    if key in src and key not in cur:
        cur[key] = src[key]

tmp = target + ".lazy.tmp"
with open(tmp, "w") as fh:
    json.dump(cur, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, target)
' "$1"
}

merge_with_node() {
    printf '%s' "$CFG_B64" | base64 -d | node -e '
const fs = require("fs");
const target = process.argv[1];
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", c => { raw += c; });
process.stdin.on("end", () => {
  const src = JSON.parse(raw);
  let cur = {};
  try { cur = JSON.parse(fs.readFileSync(target, "utf8")); } catch (e) { cur = {}; }
  if (!cur || typeof cur !== "object" || Array.isArray(cur)) cur = {};
  if (src.oauthAccount) cur.oauthAccount = src.oauthAccount;
  cur.hasCompletedOnboarding = true;
  for (const k of ["lastOnboardingVersion", "userID"]) {
    if (k in src && !(k in cur)) cur[k] = src[k];
  }
  const tmp = target + ".lazy.tmp";
  fs.writeFileSync(tmp, JSON.stringify(cur, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, target);
});
' "$1"
}

merge_claude_config() {
    config="$1"

    if [ -z "${CFG_B64:-}" ]; then
        echo "MERGE=skipped-no-source-config"
        return 0
    fi

    if [ -s "$config" ]; then
        cp -p "$config" "${config}.lazy.bak"
        echo "CONFIG_BACKUP=${config}.lazy.bak"
    fi

    # Stderr is dropped on purpose: on Windows "python3" is often the Microsoft
    # Store alias stub, which is on PATH, fails loudly and means nothing here.
    # The exit code is what decides whether to fall through to node.
    if command -v python3 >/dev/null 2>&1 && merge_with_python "$config" 2>/dev/null; then
        echo "MERGE=python3"
    elif command -v node >/dev/null 2>&1 && merge_with_node "$config" 2>/dev/null; then
        echo "MERGE=node"
    elif command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1; then
        rm -f "${config}.lazy.tmp"
        echo "MERGE=failed"
    else
        rm -f "${config}.lazy.tmp"
        echo "MERGE=skipped-no-json-tool"
    fi
}
MERGE_SNIPPET
}

eval "$(merge_snippet)"

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
        merge_snippet
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

merge_claude_config "$HOME/.claude.json"
REMOTE_PUSH
    } | run_in_distro "$distro" bash -s 2>&1 | tr -d '\r'
}

# The other direction. Reading is a separate step from writing so the host file
# is only touched once the distro has actually handed over a payload.
read_from_distro() {
    local distro="$1"

    {
        cat <<'REMOTE_PULL'
set -u
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cred="$dir/.credentials.json"

if [ ! -f "$cred" ]; then
    echo "ERR=no-credentials"
    exit 0
fi

echo "CRED_B64=$(base64 -w0 < "$cred")"
echo "SHA=$(sha256sum < "$cred" | cut -d' ' -f1)"

config="$HOME/.claude.json"
if [ -s "$config" ]; then
    echo "CFG_B64=$(base64 -w0 < "$config")"
fi
REMOTE_PULL
    } | run_in_distro "$distro" bash -s 2>/dev/null | tr -d '\r'
}

# Always called through $(...), so the umask stays inside that subshell.
install_on_host() {
    local cred_b64="$1"

    umask 077
    mkdir -p "$HOST_DIR" || return 1

    if [ -s "$HOST_CRED" ]; then
        cp -p "$HOST_CRED" "${HOST_CRED}.lazy.bak"
        echo "BACKUP=${HOST_CRED}.lazy.bak"
    fi

    printf '%s' "$cred_b64" | base64 -d > "${HOST_CRED}.lazy.tmp" || return 1
    chmod 600 "${HOST_CRED}.lazy.tmp"
    mv -f "${HOST_CRED}.lazy.tmp" "$HOST_CRED" || return 1
    echo "WROTE=${HOST_CRED}"
    echo "SHA=$(sha256sum < "$HOST_CRED" | cut -d' ' -f1)"

    CFG_B64="$2"
    merge_claude_config "$HOST_CONFIG"
}

# ---------------------------------------------------------------------- main

if ! is_git_bash; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
        say_err "You are already inside WSL."
        echo "Run this from Git Bash on the Windows host - it drives both sides from there:" >&2
        echo "  lazy claude.auth ${DISTRO:-<distro>}" >&2
    else
        say_err "This syncs a Windows login with WSL, so it only runs on Windows (Git Bash)."
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

HOST_KIND=missing
HOST_SHA=""
HOST_EXPIRES=""
if [ -f "$HOST_CRED" ]; then
    if cred_has_token "$HOST_CRED"; then HOST_KIND=token; else HOST_KIND=empty; fi
    HOST_SHA="$(sha256sum < "$HOST_CRED" | cut -d' ' -f1)"
    HOST_EXPIRES="$(cred_expiry_ms "$HOST_CRED")"
fi
HOST_STATE="$(classify_cred "$HOST_KIND" "$HOST_EXPIRES")"

printf '%sHost (Windows):%s\n' "$c_bold" "$c_reset"
say_dim "$HOST_CRED"
report_state "$HOST_STATE" "$HOST_EXPIRES"
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
D_EXPIRES="$(probe_value "$PROBE" EXPIRES)"
D_CLI="$(probe_value "$PROBE" CLI)"
D_STATE="$(classify_cred "$D_CRED" "$D_EXPIRES")"

say_dim "user: ${D_USER}   config: ${D_DIR}"
report_state "$D_STATE" "$D_EXPIRES"

if [ "$D_CLI" = "missing" ]; then
    say_warn "claude CLI not found here"
else
    say_dim "cli:  ${D_CLI}"
fi
echo ""

# ----------------------------------------------------------------- direction

# Whichever side is in better shape is the source. Two sides in the same shape
# fall back to the later expiry: that is the one refreshed most recently.
DIRECTION=""
REASON=""

if [ -n "$D_SHA" ] && [ "$D_SHA" = "$HOST_SHA" ]; then
    DIRECTION="insync"
else
    H_RANK="$(state_rank "$HOST_STATE")"
    D_RANK="$(state_rank "$D_STATE")"

    if [ "$H_RANK" -gt "$D_RANK" ]; then
        DIRECTION="push"
        REASON="the host holds the usable login"
    elif [ "$D_RANK" -gt "$H_RANK" ]; then
        DIRECTION="pull"
        REASON="the host login is not usable and ${DISTRO}'s is"
    elif [ "$H_RANK" -lt 2 ]; then
        DIRECTION="none"
    elif [ -n "$D_EXPIRES" ] && [ -n "$HOST_EXPIRES" ] && [ "$D_EXPIRES" -gt "$HOST_EXPIRES" ]; then
        DIRECTION="pull"
        REASON="${DISTRO} holds the more recently refreshed token"
    else
        DIRECTION="push"
        REASON="the host holds the more recently refreshed token"
    fi
fi

OVERRIDDEN=""
if [ -n "$FORCED" ] && [ "$FORCED" != "$DIRECTION" ]; then
    OVERRIDDEN="$DIRECTION"
    DIRECTION="$FORCED"
    REASON="forced with --${FORCED}"
fi

case "$DIRECTION" in
    push) SRC_LABEL="host";   DST_LABEL="$DISTRO"; SRC_STATE="$HOST_STATE" ;;
    pull) SRC_LABEL="$DISTRO"; DST_LABEL="host";   SRC_STATE="$D_STATE" ;;
    *)    SRC_LABEL="";        DST_LABEL="";       SRC_STATE="" ;;
esac

if [ "$DIRECTION" = "insync" ]; then
    echo "Both sides hold the same login - nothing to copy."
    exit 0
fi

if [ "$DIRECTION" = "none" ]; then
    say_err "Neither side holds a login to copy."
    echo "Sign in on one of them first - 'claude' on Windows, or inside ${DISTRO} -" >&2
    echo "then run this again." >&2
    exit 1
fi

printf '%sDirection:%s %s -> %s' "$c_bold" "$c_reset" "$SRC_LABEL" "$DST_LABEL"
if [ -n "$REASON" ]; then
    printf ' %s(%s)%s' "$c_dim" "$REASON" "$c_reset"
fi
printf '\n'

if [ -n "$OVERRIDDEN" ]; then
    case "$OVERRIDDEN" in
        insync) say_dim "both sides already hold this login" ;;
        none)   say_dim "neither side looks signed in" ;;
        *)      say_dim "left alone, this run would have gone the other way (${OVERRIDDEN})" ;;
    esac
fi

if [ "$SRC_STATE" = "expired" ]; then
    say_warn "the source token is expired too - copying it only helps if its refresh token still works"
elif [ "$SRC_STATE" != "valid" ]; then
    say_err "The ${SRC_LABEL} side has no token to copy."
    exit 1
fi

if [ "$DIRECTION" = "push" ] && [ "$D_CLI" = "missing" ]; then
    say_warn "no claude CLI in ${DISTRO} - the login is copied anyway, install it later"
fi
echo ""

if [ "$CHECK_ONLY" -eq 1 ]; then
    # Repeat the forcing flag: without it the same run would pick its own way.
    if [ -n "$OVERRIDDEN" ]; then
        echo "Run 'lazy claude.auth ${DISTRO} --${DIRECTION}' to copy ${SRC_LABEL} -> ${DST_LABEL}."
    else
        echo "Run 'lazy claude.auth ${DISTRO}' to copy ${SRC_LABEL} -> ${DST_LABEL}."
    fi
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        say_err "Refusing to overwrite credentials without confirmation (no terminal). Use -y."
        exit 1
    fi
    if [ "$DIRECTION" = "push" ]; then
        printf 'Copy the host login into %s (%s)? [y/N] ' "$DISTRO" "${D_DIR}/.credentials.json"
    else
        printf "Copy %s's login onto this host (%s)? [y/N] " "$DISTRO" "$HOST_CRED"
    fi
    read -r REPLY_YN
    case "$REPLY_YN" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
    echo ""
fi

if [ "$DIRECTION" = "push" ]; then
    CRED_B64="$(base64 -w0 < "$HOST_CRED")"
    CFG_B64=""
    if [ -s "$HOST_CONFIG" ]; then
        CFG_B64="$(base64 -w0 < "$HOST_CONFIG")"
    fi

    RESULT="$(push_credentials "$DISTRO" "$CRED_B64" "$CFG_B64")"
    STATUS=$?
    WANT_SHA="$HOST_SHA"
else
    PULLED="$(read_from_distro "$DISTRO")"
    if [ -z "$PULLED" ] || [ -n "$(probe_value "$PULLED" ERR)" ]; then
        say_err "Could not read the credentials out of ${DISTRO}."
        exit 1
    fi

    RESULT="$(install_on_host \
        "$(probe_value "$PULLED" CRED_B64)" \
        "$(probe_value "$PULLED" CFG_B64)")"
    STATUS=$?
    WANT_SHA="$(probe_value "$PULLED" SHA)"
fi

if [ "$STATUS" -ne 0 ]; then
    say_err "Copy failed."
    printf '%s\n' "$RESULT" | sed 's/^/  /' >&2
    exit 1
fi

NEW_SHA="$(probe_value "$RESULT" SHA)"
BACKUP="$(probe_value "$RESULT" BACKUP)"
CFG_BACKUP="$(probe_value "$RESULT" CONFIG_BACKUP)"
MERGE="$(probe_value "$RESULT" MERGE)"

if [ "$NEW_SHA" != "$WANT_SHA" ]; then
    say_err "The copy landed but does not match the source file."
    printf '%s\n' "$RESULT" | sed 's/^/  /' >&2
    exit 1
fi

say_ok "credentials copied and verified (sha256 matches)"

case "$MERGE" in
    python3|node)
        say_ok "account + onboarding flags merged into ~/.claude.json on the ${DST_LABEL} side" ;;
    skipped-no-json-tool)
        say_warn "no python3 or node on the ${DST_LABEL} side: ~/.claude.json untouched, claude may run onboarding once" ;;
    failed)
        say_warn "could not rewrite ~/.claude.json on the ${DST_LABEL} side: left untouched, claude may run onboarding once" ;;
    skipped-no-source-config)
        say_warn "no ~/.claude.json on the ${SRC_LABEL} side to merge from" ;;
esac

[ -n "$BACKUP" ] && say_dim "previous credentials: ${BACKUP}"
[ -n "$CFG_BACKUP" ] && say_dim "previous config:      ${CFG_BACKUP}"

echo ""
if [ "$DIRECTION" = "push" ]; then
    echo "Done. Try it:"
    echo "  wsl -d ${DISTRO}"
    echo "  claude"
else
    echo "Done. Try 'claude' here on Windows."
fi
