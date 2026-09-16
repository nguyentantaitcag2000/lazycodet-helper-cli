#!/bin/bash
# Switch between saved Claude Code logins, and add new ones through the
# browser OAuth flow.
#
# The hard part is not copying tokens around, it is not breaking the account you
# switch away from. Claude Code rotates the refresh token every time it renews
# the access token, so a copy archived at switch time goes stale the moment that
# account is used again. Every run therefore starts by writing the live tokens
# back into the profile that owns them, and only ever does so when the live
# account identity matches what the profile recorded.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

usage() {
    echo "Usage:"
    echo "  lazy claude                  Pick a saved account and switch to it"
    echo "  lazy claude <name>           Switch to a saved account by name"
    echo "  lazy claude --add [--name n] Sign in to another account and switch to it"
    echo "  lazy claude --list           List the saved accounts and exit"
    echo "  lazy claude --current        Print the active account name and exit"
    echo "  lazy claude --remove <name>  Forget a saved account"
    echo ""
    echo "Saved logins live in ~/.claude-accounts, one directory per account."
    echo "Adding an account runs the OAuth flow in an isolated config directory,"
    echo "so the account you are signed in as right now is never touched."
    echo ""
    echo "In the picker: up/down move, ENTER switches, [a] add, [d] forget,"
    echo "[q] or ESC quits."
    echo ""
    echo "Options:"
    echo "      --name <name>  Name to save the new account under (with --add)"
    echo "  -y, --yes          Skip confirmation prompts"
    echo "  -h, --help         Show this help"
}

MODE="pick"
TARGET=""
NEW_NAME=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --list) MODE="list" ;;
        --current) MODE="current" ;;
        --add) MODE="add" ;;
        --remove|--forget)
            MODE="remove"
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --remove needs an account name" >&2
                exit 1
            fi
            TARGET="$1"
            ;;
        --name)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --name needs a value" >&2
                exit 1
            fi
            NEW_NAME="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1"; echo ""; usage; exit 1 ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "Error: Only one account name is accepted -> $1" >&2
                exit 1
            fi
            TARGET="$1"
            if [ "$MODE" = "pick" ]; then
                MODE="switch"
            fi
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------- colors

c_bold=""; c_dim=""; c_ok=""; c_warn=""; c_err=""; c_sel=""; c_reset=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_ok=$'\033[32m'
    c_warn=$'\033[33m'; c_err=$'\033[31m'; c_sel=$'\033[1;36m'; c_reset=$'\033[0m'
fi

say_ok()   { printf '  %s%s%s\n' "$c_ok" "$1" "$c_reset"; }
say_warn() { printf '  %s%s%s\n' "$c_warn" "$1" "$c_reset"; }
say_dim()  { printf '  %s%s%s\n' "$c_dim" "$1" "$c_reset"; }
say_err()  { printf '%sError: %s%s\n' "$c_err" "$1" "$c_reset" >&2; }

# The picker draws straight to the terminal so nothing it paints lands in the
# stdout the caller captures. The overrides exist so the tests can drive the key
# handling from a file; nothing else sets them.
TTY_IN="${LAZY_CLAUDE_TTY_IN:-/dev/tty}"
TTY_OUT="${LAZY_CLAUDE_TTY_OUT:-/dev/tty}"

NOW_MS="$(( $(date +%s) * 1000 ))"

# Epoch milliseconds to a readable stamp. GNU date and BSD date disagree on the
# flag, so try both rather than branching on the platform.
fmt_ms() {
    local sec
    [ -n "${1:-}" ] || return 1
    sec="$(( $1 / 1000 ))"
    date -d "@${sec}" '+%Y-%m-%d %H:%M' 2>/dev/null && return 0
    date -r "${sec}" '+%Y-%m-%d %H:%M' 2>/dev/null && return 0
    return 1
}

# ------------------------------------------------------------------ json tools

# Reading oauthAccount out of ~/.claude.json and writing it back needs a real
# JSON parser: that file also carries every project's history, and a regex edit
# would corrupt it. node is tried first because Claude Code users almost always
# have it; python3 covers the native installs that do not.
JSON_RUNNER=""

JSON_GET_NODE='
const fs = require("fs");
let v;
try { v = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(0); }
for (const k of String(process.argv[2]).split(".")) {
  if (v === null || typeof v !== "object") { v = undefined; break; }
  v = v[k];
}
if (v === undefined || v === null) process.exit(0);
process.stdout.write(typeof v === "string" ? v : JSON.stringify(v));
'

JSON_GET_PY='
import json, sys
try:
    with open(sys.argv[1]) as fh:
        v = json.load(fh)
except Exception:
    sys.exit(0)
for k in sys.argv[2].split("."):
    if not isinstance(v, dict):
        v = None
        break
    v = v.get(k)
    if v is None:
        break
if v is None:
    sys.exit(0)
sys.stdout.write(v if isinstance(v, str) else json.dumps(v))
'

# Folds a patch object into the target file: a null value deletes that key,
# anything else replaces it. Everything the patch does not mention - project
# history, MCP servers, settings - is left exactly as it was.
JSON_PATCH_NODE='
const fs = require("fs");
const f = process.argv[1];
const patch = JSON.parse(fs.readFileSync(0, "utf8"));
let cur = {};
try { cur = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { cur = {}; }
if (!cur || typeof cur !== "object" || Array.isArray(cur)) cur = {};
for (const k of Object.keys(patch)) {
  if (patch[k] === null) delete cur[k]; else cur[k] = patch[k];
}
const t = f + ".lazy.tmp";
fs.writeFileSync(t, JSON.stringify(cur, null, 2), { mode: 0o600 });
fs.renameSync(t, f);
'

JSON_PATCH_PY='
import json, os, sys
f = sys.argv[1]
patch = json.loads(sys.stdin.read())
try:
    with open(f) as fh:
        cur = json.load(fh)
except Exception:
    cur = {}
if not isinstance(cur, dict):
    cur = {}
for k, v in patch.items():
    if v is None:
        cur.pop(k, None)
    else:
        cur[k] = v
t = f + ".lazy.tmp"
with open(t, "w") as fh:
    json.dump(cur, fh, indent=2)
os.chmod(t, 0o600)
os.replace(t, f)
'

detect_json_runner() {
    # The override exists so the tests can exercise both readers on a machine
    # that has both; nothing else sets it.
    case "${LAZY_CLAUDE_JSON_RUNNER:-}" in
        node|python3) JSON_RUNNER="$LAZY_CLAUDE_JSON_RUNNER"; return 0 ;;
    esac
    if command -v node >/dev/null 2>&1 && node -e '' >/dev/null 2>&1; then
        JSON_RUNNER=node
        return 0
    fi
    # Stderr is dropped on purpose: on Windows "python3" is often the Microsoft
    # Store alias stub, which is on PATH and fails loudly without meaning much.
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
        JSON_RUNNER=python3
        return 0
    fi
    return 1
}

json_get() {
    case "$JSON_RUNNER" in
        node) node -e "$JSON_GET_NODE" "$1" "$2" 2>/dev/null ;;
        python3) python3 -c "$JSON_GET_PY" "$1" "$2" 2>/dev/null ;;
    esac
}

json_patch() {
    case "$JSON_RUNNER" in
        node) node -e "$JSON_PATCH_NODE" "$1" ;;
        python3) python3 -c "$JSON_PATCH_PY" "$1" ;;
    esac
}

# ------------------------------------------------------------------ live login

# Where Claude Code keeps its state. CLAUDE_CONFIG_DIR moves both files, not
# just the directory: with it set, the config lands inside it instead of $HOME.
LIVE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
LIVE_CRED="${LIVE_DIR}/.credentials.json"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    LIVE_CONFIG="${LIVE_DIR}/.claude.json"
else
    LIVE_CONFIG="${HOME}/.claude.json"
fi
LIVE_POLICY="${LIVE_DIR}/policy-limits.json"

KEYCHAIN_SERVICE="${LAZY_CLAUDE_KEYCHAIN_SERVICE:-Claude Code-credentials}"
KEYCHAIN_ACCOUNT="$(id -un 2>/dev/null || echo "${USER:-}")"

keychain_read() {
    security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null ||
        security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
}

# macOS keeps the tokens in the login keychain rather than in a file, but only
# on some builds - and a config directory that already holds a credentials file
# is authoritative either way. Probe instead of assuming.
CRED_BACKEND="file"
detect_cred_backend() {
    if [ -s "$LIVE_CRED" ]; then
        CRED_BACKEND="file"
        return
    fi
    if is_macos && command -v security >/dev/null 2>&1; then
        if [ -n "$(keychain_read)" ] || [ ! -e "$LIVE_CRED" ]; then
            CRED_BACKEND="keychain"
            return
        fi
    fi
    CRED_BACKEND="file"
}

live_cred_read() {
    case "$CRED_BACKEND" in
        keychain) keychain_read ;;
        *) [ -f "$LIVE_CRED" ] && cat "$LIVE_CRED" ;;
    esac
}

live_cred_write() {
    local payload
    local tmp

    payload="$(cat)"
    [ -n "$payload" ] || return 1

    case "$CRED_BACKEND" in
        keychain)
            security add-generic-password -U \
                -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" \
                -w "$payload" >/dev/null 2>&1 || return 1
            ;;
        *)
            mkdir -p "$LIVE_DIR" || return 1
            tmp="${LIVE_CRED}.lazy.tmp"
            printf '%s\n' "$payload" > "$tmp" || return 1
            chmod 600 "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$LIVE_CRED" || return 1
            ;;
    esac
}

# An empty accessToken is what a logout leaves behind. On disk that looks
# exactly like a login until you read the value, and archiving it would destroy
# the saved account it was meant to protect.
has_token() {
    printf '%s' "$1" | grep -qE '"accessToken"[[:space:]]*:[[:space:]]*"[^"]'
}

cred_number_field() {
    printf '%s' "$1" |
        grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" |
        grep -oE '[0-9]+$' | head -1
}

cred_text_field() {
    printf '%s' "$1" |
        grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
        head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# ----------------------------------------------------------------------- store

STORE="${LAZY_CLAUDE_STORE:-${HOME}/.claude-accounts}"
ACTIVE_FILE="${STORE}/active"

# Account-scoped caches in ~/.claude.json. Carrying them across a switch shows
# the previous account's plan, limits and model list until Claude Code happens
# to refresh them, so they are dropped and refetched.
STALE_KEYS="cachedUsageUtilization modelAccessCache orgModelDefaultCache \
additionalModelOptionsCache additionalModelCostsCache additionalModelOptionsAnsweredAt \
cachedExtraUsageDisabledReason metricsStatusCache clientDataCacheSlots cachedArtifactRoster"

ensure_store() {
    mkdir -p "$STORE" || return 1
    chmod 700 "$STORE" 2>/dev/null || true
}

profile_dir()  { printf '%s/%s' "$STORE" "$1"; }
profile_cred() { printf '%s/%s/credentials.json' "$STORE" "$1"; }
profile_meta() { printf '%s/%s/account.json' "$STORE" "$1"; }

profile_exists() {
    [ -n "${1:-}" ] && [ -f "$(profile_meta "$1")" ]
}

list_profiles() {
    local entry
    local name

    [ -d "$STORE" ] || return 0
    for entry in "$STORE"/*/; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        case "$name" in .*) continue ;; esac
        [ -f "${entry}account.json" ] || continue
        printf '%s\n' "$name"
    done
}

active_profile() {
    [ -f "$ACTIVE_FILE" ] || return 0
    tr -d '[:space:]' < "$ACTIVE_FILE"
}

set_active_profile() {
    printf '%s\n' "$1" > "$ACTIVE_FILE"
    chmod 600 "$ACTIVE_FILE" 2>/dev/null || true
}

clear_active_profile() {
    rm -f "$ACTIVE_FILE"
}

profile_id()    { json_get "$(profile_meta "$1")" oauthAccount.accountUuid; }
profile_email() { json_get "$(profile_meta "$1")" oauthAccount.emailAddress; }
profile_org()   { json_get "$(profile_meta "$1")" oauthAccount.organizationName; }

# A name derived from the email local part, kept to characters that are safe in
# a directory name and in a shell argument.
slugify() {
    printf '%s' "$1" |
        sed 's/@.*//' |
        tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//' |
        cut -c1-32
}

unique_slug() {
    local base="$1"
    local candidate
    local n=2

    [ -n "$base" ] || base="account"
    candidate="$base"
    while profile_exists "$candidate"; do
        candidate="${base}-${n}"
        n=$((n + 1))
    done
    printf '%s' "$candidate"
}

# Writes the credentials and the identity of one account into its profile. The
# previous credentials are kept as .bak so a bad capture can be undone by hand;
# nothing is written when the payload carries no token.
save_profile() {
    local slug="$1"
    local cred="$2"
    local account="$3"
    local user_id="$4"
    local dir
    local meta
    local target

    has_token "$cred" || return 1

    dir="$(profile_dir "$slug")"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true

    target="$(profile_cred "$slug")"
    if [ -f "$target" ] && ! printf '%s\n' "$cred" | cmp -s - "$target"; then
        cp -p "$target" "${target}.bak" 2>/dev/null || true
    fi
    printf '%s\n' "$cred" > "${target}.tmp" || return 1
    chmod 600 "${target}.tmp" 2>/dev/null || true
    mv -f "${target}.tmp" "$target" || return 1

    meta="$(profile_meta "$slug")"
    : > "${meta}.tmp" || return 1
    chmod 600 "${meta}.tmp" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "savedAt": %s' "$NOW_MS"
        if [ -n "$account" ]; then
            printf ',\n  "oauthAccount": %s' "$account"
        fi
        if [ -n "$user_id" ]; then
            printf ',\n  "userID": "%s"' "$user_id"
        fi
        printf '\n}\n'
    } > "${meta}.tmp"
    mv -f "${meta}.tmp" "$meta" || return 1
}

# ---------------------------------------------------------------- capture back

# Claude Code rotates the refresh token on every renewal, so the archived copy
# of the account in use goes stale the moment that account is used. Called at
# the start of every run, this folds the live tokens back into the profile that
# owns them - which is what keeps the account you are about to leave usable.
LIVE_ID=""
LIVE_UNARCHIVED=0
CAPTURE_NOTES=""

add_note() {
    CAPTURE_NOTES="${CAPTURE_NOTES}${1}
"
}

print_notes() {
    local line
    [ -n "$CAPTURE_NOTES" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        say_dim "$line"
    done <<EOF
$CAPTURE_NOTES
EOF
}

capture_live() {
    local live_cred
    local active
    local candidate
    local account
    local user_id

    live_cred="$(live_cred_read)"
    has_token "$live_cred" || return 0

    LIVE_ID="$(json_get "$LIVE_CONFIG" oauthAccount.accountUuid)"
    account="$(json_get "$LIVE_CONFIG" oauthAccount)"
    user_id="$(json_get "$LIVE_CONFIG" userID)"

    if [ -z "$LIVE_ID" ]; then
        LIVE_UNARCHIVED=1
        add_note "the current login has no account record in ${LIVE_CONFIG}, so it was not archived"
        return 0
    fi

    active="$(active_profile)"
    if [ -n "$active" ] && profile_exists "$active"; then
        if [ "$(profile_id "$active")" = "$LIVE_ID" ]; then
            save_profile "$active" "$live_cred" "$account" "$user_id" || true
            return 0
        fi
        add_note "the live login is not '${active}' any more - somebody signed in outside lazy"
        clear_active_profile
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if [ "$(profile_id "$candidate")" = "$LIVE_ID" ]; then
            save_profile "$candidate" "$live_cred" "$account" "$user_id" || return 0
            set_active_profile "$candidate"
            add_note "the live login belongs to '${candidate}', now marked as the one in use"
            return 0
        fi
    done <<EOF
$(list_profiles)
EOF

    candidate="$(unique_slug "$(slugify "$(json_get "$LIVE_CONFIG" oauthAccount.emailAddress)")")"
    save_profile "$candidate" "$live_cred" "$account" "$user_id" || return 0
    set_active_profile "$candidate"
    add_note "saved the login you are signed in with as '${candidate}'"
}

# ------------------------------------------------------------------- rendering

row_status() {
    local cred
    local expires
    local refresh_expires
    local when

    cred="$(cat "$(profile_cred "$1")" 2>/dev/null)"
    if ! has_token "$cred"; then
        printf 'no token - sign in again'
        return
    fi

    expires="$(cred_number_field "$cred" expiresAt)"
    refresh_expires="$(cred_number_field "$cred" refreshTokenExpiresAt)"

    if [ -n "$expires" ] && [ "$expires" -gt "$NOW_MS" ]; then
        when="$(fmt_ms "$expires" || true)"
        if [ -n "$when" ]; then
            printf 'token valid until %s' "$when"
        else
            printf 'token valid'
        fi
        return
    fi

    if [ -n "$refresh_expires" ] && [ "$refresh_expires" -le "$NOW_MS" ]; then
        printf 'expired - sign in again'
        return
    fi

    printf 'renews on next use'
}

row_plan() {
    local cred
    cred="$(cat "$(profile_cred "$1")" 2>/dev/null)"
    cred_text_field "$cred" subscriptionType
}

# Column widths are measured over every row first so the list stays aligned
# however long the names and addresses are.
W_NAME=0
W_MAIL=0
W_PLAN=0

measure_rows() {
    local slug
    local value

    W_NAME=0; W_MAIL=0; W_PLAN=0
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        if [ "${#slug}" -gt "$W_NAME" ]; then W_NAME="${#slug}"; fi
        value="$(profile_email "$slug")"
        if [ "${#value}" -gt "$W_MAIL" ]; then W_MAIL="${#value}"; fi
        value="$(row_plan "$slug")"
        if [ "${#value}" -gt "$W_PLAN" ]; then W_PLAN="${#value}"; fi
    done <<EOF
$(list_profiles)
EOF
}

render_row() {
    local slug="$1"
    local marker="$2"
    local email
    local plan

    email="$(profile_email "$slug")"
    [ -n "$email" ] || email="-"
    plan="$(row_plan "$slug")"
    [ -n "$plan" ] || plan="-"

    printf '%s %-*s  %-*s  %-*s  %s' \
        "$marker" \
        "$W_NAME" "$slug" \
        "$W_MAIL" "$email" \
        "$W_PLAN" "$plan" \
        "$(row_status "$slug")"
}

# ------------------------------------------------------------------ the switch

# Best effort only, and deliberately a warning rather than a block: a running
# session still holds the old account's tokens in memory and writes them back on
# its next renewal, which would land them on top of the account just switched in.
claude_is_running() {
    if is_git_bash; then
        tasklist "$(win_flag FI)" "IMAGENAME eq claude.exe" 2>/dev/null |
            grep -qi 'claude\.exe'
        return
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x claude >/dev/null 2>&1
        return
    fi
    return 1
}

confirm() {
    local answer=""

    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    if [ ! -t 0 ] && [ ! -e "$TTY_IN" ]; then
        say_err "Refusing to change the login without confirmation (no terminal). Use -y."
        exit 1
    fi

    printf '%s [y/N] ' "$1"
    if ! read -r answer < "$TTY_IN" 2>/dev/null; then
        echo ""
        return 1
    fi
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# The one case where switching can actually lose a login: the tokens on the
# machine work, but nothing says whose they are, so they could not be archived.
# Overwriting them then leaves only the .lazy.bak copy.
warn_if_unarchived() {
    [ "$LIVE_UNARCHIVED" -eq 1 ] || return 0
    say_warn "the login on this machine could not be archived - it has no account record"
    say_dim "switching replaces it, and only ${LIVE_CRED}.lazy.bak would be left"
    say_dim "run 'claude' once first so it writes its account back into ${LIVE_CONFIG}"
    confirm "Switch anyway?"
}

warn_if_running() {
    claude_is_running || return 0
    say_warn "a claude session looks like it is still running"
    say_dim "it writes its own tokens back when it renews them, which would land on"
    say_dim "top of the account you are switching to - close it first"
    confirm "Switch anyway?"
}

switch_to() {
    local slug="$1"
    local cred
    local account
    local user_id
    local patch
    local key
    local readback

    cred="$(cat "$(profile_cred "$slug")" 2>/dev/null)"
    if ! has_token "$cred"; then
        say_err "'${slug}' has no usable token saved. Run 'lazy claude --add' to sign in again."
        return 1
    fi

    account="$(json_get "$(profile_meta "$slug")" oauthAccount)"
    user_id="$(json_get "$(profile_meta "$slug")" userID)"

    if [ "$CRED_BACKEND" = "file" ] && [ -s "$LIVE_CRED" ]; then
        cp -p "$LIVE_CRED" "${LIVE_CRED}.lazy.bak" 2>/dev/null || true
    fi
    if [ -s "$LIVE_CONFIG" ]; then
        cp -p "$LIVE_CONFIG" "${LIVE_CONFIG}.lazy.bak" 2>/dev/null || true
    fi

    if ! printf '%s' "$cred" | live_cred_write; then
        say_err "Could not write the credentials to the ${CRED_BACKEND} store."
        return 1
    fi

    # Read the tokens back through the same store before touching anything
    # else: a write that did not land must not be followed by a config rewrite
    # that claims the new account is signed in.
    readback="$(live_cred_read)"
    if [ "$readback" != "$cred" ]; then
        say_err "The credentials did not land intact - the login was left as it was."
        if [ "$CRED_BACKEND" = "file" ] && [ -s "${LIVE_CRED}.lazy.bak" ]; then
            cp -p "${LIVE_CRED}.lazy.bak" "$LIVE_CRED"
            say_dim "restored ${LIVE_CRED}"
        fi
        return 1
    fi

    if [ -n "$account" ]; then
        patch="{\"oauthAccount\":${account},\"hasCompletedOnboarding\":true"
        case "$user_id" in
            "") ;;
            *[!A-Za-z0-9_.:-]*) ;;
            *) patch="${patch},\"userID\":\"${user_id}\"" ;;
        esac
        # STALE_KEYS is a space-separated list written just above; splitting it
        # is the point.
        # shellcheck disable=SC2086
        for key in $STALE_KEYS; do
            patch="${patch},\"${key}\":null"
        done
        patch="${patch}}"

        if ! printf '%s' "$patch" | json_patch "$LIVE_CONFIG" 2>/dev/null; then
            say_warn "could not update ${LIVE_CONFIG}; claude may ask the onboarding questions once"
        fi
    else
        say_warn "'${slug}' has no account record saved; claude may ask the onboarding questions once"
    fi

    # Cached plan limits belong to the account that fetched them.
    if [ -f "$LIVE_POLICY" ]; then
        mv -f "$LIVE_POLICY" "${LIVE_POLICY}.lazy.bak" 2>/dev/null || true
    fi

    set_active_profile "$slug"
    return 0
}

report_switch() {
    local slug="$1"
    local email
    local org

    email="$(profile_email "$slug")"
    org="$(profile_org "$slug")"

    echo ""
    say_ok "now signed in as '${slug}'"
    if [ -n "$email" ]; then
        say_dim "${email}${org:+   ${org}}"
    fi
    say_dim "$(row_status "$slug")"
    echo ""
    echo "Run 'claude' to use it."
}

# -------------------------------------------------------------- add an account

claude_bin() {
    if command -v claude >/dev/null 2>&1; then
        command -v claude
        return 0
    fi
    if [ -x "${HOME}/.local/bin/claude" ]; then
        printf '%s' "${HOME}/.local/bin/claude"
        return 0
    fi
    return 1
}

# The login runs against a throwaway CLAUDE_CONFIG_DIR, so on Linux, WSL and
# Git Bash the account currently signed in is not touched at all - even if the
# browser flow is abandoned half way.
add_account() {
    local bin
    local pending
    local cred
    local account
    local user_id
    local slug
    local existing
    local new_id
    local status=0

    if ! bin="$(claude_bin)"; then
        say_err "The 'claude' CLI was not found on PATH, so a new account cannot be signed in."
        return 1
    fi

    ensure_store || return 1
    pending="$(mktemp -d "${STORE}/.pending.XXXXXX")" || return 1

    echo ""
    printf '%sSigning in to another account%s\n' "$c_bold" "$c_reset"
    if [ "$CRED_BACKEND" = "keychain" ]; then
        say_dim "this Mac keeps tokens in the keychain, so the sign-in replaces the one"
        say_dim "there - the account in use was archived first"
    else
        say_dim "runs in a throwaway config dir; the account in use is left alone"
    fi
    echo ""

    CLAUDE_CONFIG_DIR="$pending" "$bin" auth login || status=$?
    echo ""

    # The isolated config dir holds the new tokens everywhere except on a Mac
    # that keeps them in the keychain, where the sign-in has just replaced the
    # single shared entry. Anywhere else, falling back to the live store would
    # save the account already signed in under a second name.
    if [ -s "${pending}/.credentials.json" ]; then
        cred="$(cat "${pending}/.credentials.json")"
    elif [ "$CRED_BACKEND" = "keychain" ]; then
        cred="$(live_cred_read)"
    else
        cred=""
    fi

    if ! has_token "$cred"; then
        rm -rf "$pending"
        if [ "$status" -ne 0 ]; then
            say_err "The sign-in did not complete."
        else
            say_err "The sign-in finished but left no token behind."
        fi
        return 1
    fi

    account="$(json_get "${pending}/.claude.json" oauthAccount)"
    user_id="$(json_get "${pending}/.claude.json" userID)"
    new_id="$(json_get "${pending}/.claude.json" oauthAccount.accountUuid)"

    # Signing in again as an account that is already saved refreshes it rather
    # than leaving a second copy behind with a divergent refresh token.
    slug=""
    if [ -n "$new_id" ]; then
        while IFS= read -r existing; do
            [ -n "$existing" ] || continue
            if [ "$(profile_id "$existing")" = "$new_id" ]; then
                slug="$existing"
                break
            fi
        done <<EOF
$(list_profiles)
EOF
    fi

    if [ -z "$slug" ]; then
        if [ -n "$NEW_NAME" ]; then
            slug="$(slugify "$NEW_NAME")"
            if profile_exists "$slug"; then
                rm -rf "$pending"
                say_err "An account named '${slug}' is already saved."
                return 1
            fi
        else
            slug="$(unique_slug "$(slugify "$(json_get "${pending}/.claude.json" oauthAccount.emailAddress)")")"
        fi
    fi

    if ! save_profile "$slug" "$cred" "$account" "$user_id"; then
        rm -rf "$pending"
        say_err "Could not save the new account."
        return 1
    fi
    rm -rf "$pending"

    say_ok "saved as '${slug}'"

    # Always install what was just signed in, even when it is the account that
    # was already active: the sign-in issued fresh tokens, and leaving the older
    # pair live would mean the next renewal races against them.
    switch_to "$slug" || return 1
    report_switch "$slug"
}

# ------------------------------------------------------------------ the picker

MENU_KEYS=()
MENU_ROWS=()
MENU_COUNT=0
MENU_CURSOR=0
MENU_KEY=""
MENU_ANSWER=""
MENU_PACKET_INPUT=0
MENU_INPUT_FD=3
MENU_READER_PID=""
MENU_STTY_STATE=""
MENU_DRAWN=0

menu_key_at() {
    printf '%s' "${MENU_KEYS[$1]:-}"
}

menu_draw() {
    local i=0
    local line

    # Clear only the first frame. Clearing before every redraw briefly exposes
    # a blank alternate screen, which looks like the list is reloading. Later
    # frames overwrite in place; synchronized output makes the update atomic on
    # terminals that support it and is harmless on terminals that do not.
    if [ "$MENU_DRAWN" -eq 0 ]; then
        printf '\033[?2026h\033[H\033[2J' >> "$TTY_OUT"
        MENU_DRAWN=1
    else
        printf '\033[?2026h\033[H' >> "$TTY_OUT"
    fi
    printf '\n  %sClaude accounts%s\n\n' "$c_bold" "$c_reset" >> "$TTY_OUT"

    while [ "$i" -lt "$MENU_COUNT" ]; do
        line="${MENU_ROWS[$i]}"
        if [ "$i" -eq "$MENU_CURSOR" ]; then
            printf '  %s> %s%s\n' "$c_sel" "$line" "$c_reset" >> "$TTY_OUT"
        else
            printf '    %s\n' "$line" >> "$TTY_OUT"
        fi
        i=$((i + 1))
    done

    printf '\n  %s%s%s\n' "$c_dim" \
        "up/down move   ENTER switch   [a] add   [d] forget   [q] quit" "$c_reset" >> "$TTY_OUT"
    printf '\033[J\033[?2026l' >> "$TTY_OUT"
}

# The prompt goes to the terminal, not to stdout: the caller captures stdout to
# read the chosen action, and a prompt written there would be captured with it.
menu_ask() {
    local answer=""
    local restore_packet="$MENU_PACKET_INPUT"

    menu_restore_input
    printf '\033[?25h  %s ' "$1" >> "$TTY_OUT"
    IFS= read -r answer <&3 || answer=""
    printf '\033[?25l' >> "$TTY_OUT"
    MENU_ANSWER="$answer"

    if [ "$restore_packet" -eq 1 ]; then
        menu_prepare_input || return 1
    fi
}

have_terminal() {
    # An overridden input path is the test harness feeding keystrokes from a
    # file; everywhere else the picker needs a real terminal on both ends.
    if [ -n "${LAZY_CLAUDE_TTY_IN:-}" ]; then
        return 0
    fi
    [ -t 1 ] && [ -e "$TTY_IN" ]
}

leave_screen() {
    menu_restore_input
    printf '\033[?2026l\033[?25h\033[?1049l' >> "$TTY_OUT" 2>/dev/null || true
}

menu_restore_input() {
    if [ -n "$MENU_READER_PID" ]; then
        kill "$MENU_READER_PID" 2>/dev/null || true
        wait "$MENU_READER_PID" 2>/dev/null || true
        MENU_READER_PID=""
    fi
    if [ "$MENU_INPUT_FD" -eq 4 ]; then
        exec 4<&-
        MENU_INPUT_FD=3
    fi
    if [ -n "$MENU_STTY_STATE" ]; then
        stty "$MENU_STTY_STATE" <&3 2>/dev/null || true
        MENU_STTY_STATE=""
    fi
}

menu_prepare_input() {
    MENU_PACKET_INPUT=0

    # Bash `read -n1` on a Windows PTY can consume the whole console input
    # record while returning only its first byte. A single long-lived `cat`
    # reads each record intact and forwards it to a pipe, where Bash can consume
    # the bytes without loss. Keeping that proxy alive also avoids spawning a
    # `dd` process for every key press.
    if is_git_bash || [ "${LAZY_CLAUDE_PACKET_INPUT:-0}" = "1" ]; then
        MENU_PACKET_INPUT=1
        MENU_INPUT_FD=3

        # File-backed input is the test harness and needs no terminal mode.
        if [ -z "${LAZY_CLAUDE_TTY_IN:-}" ]; then
            MENU_STTY_STATE="$(stty -g <&3 2>/dev/null)" || return 1
            stty -echo -icanon min 1 time 0 <&3 2>/dev/null || {
                MENU_STTY_STATE=""
                return 1
            }
            exec 4< <(cat <&3)
            MENU_READER_PID=$!
            MENU_INPUT_FD=4
        fi
    fi
}

menu_read_packet_key() {
    local first
    local next
    local final

    IFS= read -rsn1 -u "$MENU_INPUT_FD" first || return 1
    if [ "$first" != $'\033' ]; then
        MENU_KEY="$first"
        return 0
    fi

    next=""
    if ! IFS= read -rsn1 -t 1 -u "$MENU_INPUT_FD" next; then
        MENU_KEY="escape"
        return 0
    fi

    case "$next" in
        O)
            final=""
            IFS= read -rsn1 -t 1 -u "$MENU_INPUT_FD" final || final=""
            case "$final" in
                A) MENU_KEY="up" ;;
                B) MENU_KEY="down" ;;
                *) MENU_KEY="ignore" ;;
            esac
            ;;
        '[')
            # CSI parameters (for example 1;5) end at the first final byte.
            while :; do
                final=""
                IFS= read -rsn1 -t 1 -u "$MENU_INPUT_FD" final || {
                    MENU_KEY="ignore"
                    return 0
                }
                case "$final" in
                    A) MENU_KEY="up"; return 0 ;;
                    B) MENU_KEY="down"; return 0 ;;
                    [a-zA-Z~]) MENU_KEY="ignore"; return 0 ;;
                esac
            done
            ;;
        *) MENU_KEY="ignore" ;;
    esac
}

menu_read_key() {
    local key
    local rest

    MENU_KEY=""
    if [ "$MENU_PACKET_INPUT" -eq 1 ]; then
        menu_read_packet_key
        return $?
    fi

    IFS= read -rsn1 key <&3 || return 1
    if [ "$key" = $'\033' ]; then
        # A bare ESC quits; an arrow key sends "[A"/"[B" right behind it.
        # The timeout is whole seconds because bash 3.2 rejects fractions.
        rest=""
        IFS= read -rsn2 -t 1 rest <&3 || rest=""
        case "$rest" in
            "[A") key="up" ;;
            "[B") key="down" ;;
            *) key="escape" ;;
        esac
    fi
    MENU_KEY="$key"
}

# Draws on the alternate screen the way nano does, so the picker never scrolls
# the terminal history away. Prints the chosen action on stdout.
menu_select() {
    local active="$1"
    local key
    local chosen

    trap 'leave_screen' EXIT
    trap 'leave_screen; exit 130' INT TERM
    printf '\033[?1049h\033[?25l' >> "$TTY_OUT"

    # One long-lived descriptor rather than reopening per key: an arrow sends
    # three bytes and the tail has to come off the same stream as the escape.
    exec 3< "$TTY_IN"
    menu_prepare_input || { leave_screen; return 1; }

    while :; do
        menu_draw

        menu_read_key || { leave_screen; return 1; }
        key="$MENU_KEY"

        case "$key" in
            up|k)
                if [ "$MENU_CURSOR" -gt 0 ]; then
                    MENU_CURSOR=$((MENU_CURSOR - 1))
                else
                    MENU_CURSOR=$((MENU_COUNT - 1))
                fi
                ;;
            down|j)
                if [ "$MENU_CURSOR" -lt $((MENU_COUNT - 1)) ]; then
                    MENU_CURSOR=$((MENU_CURSOR + 1))
                else
                    MENU_CURSOR=0
                fi
                ;;
            escape|q|Q) leave_screen; return 1 ;;
            ignore) ;;
            a|A) leave_screen; printf 'add'; return 0 ;;
            d|D)
                chosen="$(menu_key_at "$MENU_CURSOR")"
                if [ "$chosen" != "__add__" ]; then
                    menu_ask "Forget '${chosen}'? [y/N]" || { leave_screen; return 1; }
                    case "$MENU_ANSWER" in
                        y|Y|yes|YES) leave_screen; printf 'remove %s' "$chosen"; return 0 ;;
                    esac
                fi
                ;;
            "")
                chosen="$(menu_key_at "$MENU_CURSOR")"
                leave_screen
                if [ "$chosen" = "__add__" ]; then
                    printf 'add'
                else
                    printf 'switch %s' "$chosen"
                fi
                return 0
                ;;
        esac
    done
}

build_menu() {
    local active="$1"
    local slug
    local marker
    local i=0

    MENU_KEYS=()
    MENU_ROWS=()
    MENU_CURSOR=0

    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        MENU_KEYS[$i]="$slug"
        if [ "$slug" = "$active" ]; then marker="*"; else marker=" "; fi
        MENU_ROWS[$i]="$(render_row "$slug" "$marker")"
        if [ "$slug" = "$active" ]; then
            MENU_CURSOR="$i"
        fi
        i=$((i + 1))
    done <<EOF
$(list_profiles)
EOF

    MENU_KEYS[$i]="__add__"
    MENU_ROWS[$i]="+ add another account (browser sign-in)"
    MENU_COUNT=$((i + 1))
}

# ---------------------------------------------------------------------- remove

remove_account() {
    local slug="$1"
    local active
    local dir

    if ! profile_exists "$slug"; then
        say_err "No saved account named '${slug}'."
        return 1
    fi

    active="$(active_profile)"
    if [ "$slug" = "$active" ]; then
        say_warn "'${slug}' is the login in use right now"
        say_dim "forgetting it only drops the saved copy; claude stays signed in as it"
        confirm "Forget '${slug}' anyway?" || { echo "Cancelled."; return 0; }
        clear_active_profile
    else
        confirm "Forget '${slug}'?" || { echo "Cancelled."; return 0; }
    fi

    dir="$(profile_dir "$slug")"
    case "$dir" in
        "${STORE}/"?*) rm -rf "$dir" ;;
        *) say_err "Refusing to remove an unexpected path: ${dir}"; return 1 ;;
    esac

    say_ok "forgot '${slug}'"
}

print_list() {
    local name

    measure_rows
    echo ""
    printf '%sClaude accounts%s   %s(* = in use)%s\n\n' \
        "$c_bold" "$c_reset" "$c_dim" "$c_reset"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$name" = "$ACTIVE" ]; then
            printf '  %s\n' "$(render_row "$name" "*")"
        else
            printf '  %s\n' "$(render_row "$name" " ")"
        fi
    done <<EOF
$(list_profiles)
EOF
    echo ""
}

# ------------------------------------------------------------------------ main

if ! detect_json_runner; then
    say_err "This command needs node or python3 to read ~/.claude.json safely."
    echo "Install either one, then run it again." >&2
    exit 1
fi

ensure_store || { say_err "Could not create ${STORE}"; exit 1; }
detect_cred_backend
capture_live

ACTIVE="$(active_profile)"
PROFILE_COUNT="$(list_profiles | grep -c . || true)"

case "$MODE" in
    current)
        if [ -n "$ACTIVE" ]; then
            printf '%s\n' "$ACTIVE"
            exit 0
        fi
        echo "No saved account is in use."
        exit 1
        ;;

    list)
        print_notes
        if [ "$PROFILE_COUNT" -eq 0 ]; then
            echo "No accounts saved yet. Run 'lazy claude --add' to sign in to one."
            exit 0
        fi
        print_list
        exit 0
        ;;

    remove)
        remove_account "$TARGET"
        exit $?
        ;;

    add)
        print_notes
        add_account
        exit $?
        ;;

    switch)
        if ! profile_exists "$TARGET"; then
            say_err "No saved account named '${TARGET}'."
            echo "" >&2
            list_profiles | sed 's/^/  /' >&2
            exit 1
        fi
        if [ "$TARGET" = "$ACTIVE" ]; then
            echo "Already signed in as '${TARGET}'."
            exit 0
        fi
        warn_if_unarchived || { echo "Cancelled."; exit 0; }
        warn_if_running || { echo "Cancelled."; exit 0; }
        switch_to "$TARGET" || exit 1
        report_switch "$TARGET"
        exit 0
        ;;
esac

# ------------------------------------------------------------ interactive pick

print_notes

if ! have_terminal; then
    say_err "No terminal to show the picker on. Use 'lazy claude --list' or 'lazy claude <name>'."
    exit 1
fi

if [ "$PROFILE_COUNT" -eq 0 ]; then
    echo "No accounts saved yet."
    confirm "Sign in to one now?" || { echo "Cancelled."; exit 0; }
    add_account
    exit $?
fi

measure_rows
build_menu "$ACTIVE"

CHOICE="$(menu_select "$ACTIVE")" || { echo "Cancelled."; exit 0; }

# The action is one or two words, produced by this script - word splitting is
# exactly what is wanted here.
# shellcheck disable=SC2086
set -- $CHOICE

case "${1:-}" in
    add)
        add_account
        exit $?
        ;;
    remove)
        remove_account "${2:-}"
        exit $?
        ;;
    switch)
        if [ "${2:-}" = "$ACTIVE" ]; then
            echo "Already signed in as '${2:-}'."
            exit 0
        fi
        warn_if_unarchived || { echo "Cancelled."; exit 0; }
        warn_if_running || { echo "Cancelled."; exit 0; }
        switch_to "${2:-}" || exit 1
        report_switch "${2:-}"
        exit 0
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac
