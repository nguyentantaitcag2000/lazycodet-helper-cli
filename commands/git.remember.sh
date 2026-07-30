#!/bin/bash
#
# lazy git.remember — store the Git username/password (or token) for this repo
# so pushes/pulls stop asking. Backed by:
#
#   git config --local credential.helper "store --file=.git/.git-credentials"
#
# The credential is verified against the remote before it is saved, so a wrong
# password is caught here instead of on the next push.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

CREDENTIAL_STORE=".git/.git-credentials"
HELPER_VALUE="store --file=${CREDENTIAL_STORE}"
MAX_ATTEMPTS=3

usage() {
    echo "Usage:"
    echo "  lazy git.remember [remote] [-f]"
    echo ""
    echo "Checks whether this repository can already authenticate with the remote."
    echo "If it cannot, it asks for the username and password/token, verifies them,"
    echo "and stores them in ${CREDENTIAL_STORE} so Git stops asking."
    echo ""
    echo "Arguments:"
    echo "  remote        Remote to authenticate against (default: origin)"
    echo ""
    echo "Options:"
    echo "  -f, --force   Ask for new credentials even if one is already stored"
    echo "  -h, --help    Show this help"
}

REMOTE=""
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1"; echo ""; usage; exit 1 ;;
        *)
            if [ -n "$REMOTE" ]; then
                echo "Error: Only one remote is supported."
                exit 1
            fi
            REMOTE="$1"
            ;;
    esac
    shift
done

REMOTE="${REMOTE:-origin}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: This directory is not a Git repository."
    exit 1
fi

REMOTE_URL=$(git remote get-url "$REMOTE" 2>/dev/null)

if [ -z "$REMOTE_URL" ]; then
    echo "Error: Remote not found -> $REMOTE"
    REMOTES=$(git remote)
    if [ -n "$REMOTES" ]; then
        echo ""
        echo "Available remotes:"
        echo "$REMOTES" | sed 's/^/  /'
    fi
    exit 1
fi

# --- Split the remote URL into protocol / host[:port] / path ------------------

case "$REMOTE_URL" in
    https://*) PROTOCOL="https"; URL_REST="${REMOTE_URL#https://}" ;;
    http://*)  PROTOCOL="http";  URL_REST="${REMOTE_URL#http://}" ;;
    *)
        echo "Info: Remote '$REMOTE' does not use HTTP(S)."
        echo "      $REMOTE_URL"
        echo ""
        echo "Git only remembers a username/password for http(s) remotes."
        echo "SSH remotes authenticate with keys instead — nothing to store."
        exit 0
        ;;
esac

URL_HOSTPART="${URL_REST%%/*}"
URL_PATH="${URL_REST#"$URL_HOSTPART"}"

URL_USER=""
case "$URL_HOSTPART" in
    *@*)
        URL_USER="${URL_HOSTPART%%@*}"
        URL_USER="${URL_USER%%:*}"
        HOST="${URL_HOSTPART#*@}"
        ;;
    *) HOST="$URL_HOSTPART" ;;
esac

if [ -z "$HOST" ]; then
    echo "Error: Could not read the host from the remote URL -> $REMOTE_URL"
    exit 1
fi

# Rebuilt without any embedded credentials so verification always uses the
# username/password we are testing.
CLEAN_URL="${PROTOCOL}://${HOST}${URL_PATH}"
CREDENTIAL_PATH="${URL_PATH#/}"

use_http_path() {
    local value

    value=$(git config --type=bool --get "credential.${PROTOCOL}://${HOST}.useHttpPath" 2>/dev/null)
    if [ -z "$value" ]; then
        value=$(git config --type=bool --get credential.useHttpPath 2>/dev/null)
    fi

    [ "$value" = "true" ]
}

# Credential description fed to `git credential fill/approve/reject`.
credential_request() {
    printf 'protocol=%s\nhost=%s\n' "$PROTOCOL" "$HOST"
    if use_http_path && [ -n "$CREDENTIAL_PATH" ]; then
        printf 'path=%s\n' "$CREDENTIAL_PATH"
    fi
}

field_of() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# --- Non-interactive askpass -------------------------------------------------
# Feeding credentials through GIT_ASKPASS (instead of embedding them in the URL)
# keeps them out of the process list. With no values exported it answers with
# empty strings, which makes probing calls fail fast instead of hanging.

ASKPASS_FILE=""

cleanup() {
    if [ -n "$ASKPASS_FILE" ]; then
        rm -f "$ASKPASS_FILE"
    fi
}
trap cleanup EXIT INT TERM

ASKPASS_FILE=$(mktemp "${TMPDIR:-/tmp}/lazy-askpass.XXXXXX" 2>/dev/null)

if [ -z "$ASKPASS_FILE" ]; then
    echo "Error: Could not create a temporary file."
    exit 1
fi

cat > "$ASKPASS_FILE" <<'ASKPASS_EOF'
#!/bin/sh
case "$1" in
    *[Uu]sername*) printf '%s\n' "${LAZY_GIT_USERNAME-}" ;;
    *) printf '%s\n' "${LAZY_GIT_PASSWORD-}" ;;
esac
ASKPASS_EOF

chmod 700 "$ASKPASS_FILE"

ASKPASS_PROG="$ASKPASS_FILE"
if is_git_bash && command -v cygpath >/dev/null 2>&1; then
    # git.exe needs a Windows path; /tmp/... means nothing to it.
    ASKPASS_PROG=$(cygpath -m "$ASKPASS_FILE")
fi

# Run git with prompting fully disabled: no terminal prompt, no askpass answer,
# no Credential Manager dialog on Windows.
git_quiet() {
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS="$ASKPASS_PROG" \
    SSH_ASKPASS="$ASKPASS_PROG" \
    GCM_INTERACTIVE=never \
    git -c credential.interactive=false "$@"
}

# Same, but with the credential we want to test and every helper disabled, so
# nothing else can supply (or cache) a credential during the check.
git_as_user() {
    local user="$1" pass="$2"
    shift 2

    LAZY_GIT_USERNAME="$user" \
    LAZY_GIT_PASSWORD="$pass" \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS="$ASKPASS_PROG" \
    SSH_ASKPASS="$ASKPASS_PROG" \
    GCM_INTERACTIVE=never \
    git -c credential.helper= -c credential.interactive=false "$@"
}

# Only touch the repo-local store file, never the system/global helpers.
git_store_only() {
    git -c credential.helper= -c credential.helper="$HELPER_VALUE" "$@"
}

urlencode() {
    local string="$1"
    local out=""
    local i char

    for (( i = 0; i < ${#string}; i++ )); do
        char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) out="${out}${char}" ;;
            *) out="${out}$(printf '%%%02X' "'$char")" ;;
        esac
    done

    printf '%s' "$out"
}

is_auth_error() {
    printf '%s' "$1" | grep -qiE \
        'authentication failed|invalid username or password|invalid username or token|bad credentials|access denied|permission denied|HTTP (401|403)|error: 40[13]'
}

# GIT_ASKPASS could not run (common failure mode on exotic Windows setups):
# git fell back to the terminal, which is disabled.
is_askpass_failure() {
    printf '%s' "$1" | grep -qiE 'could not read (Username|Password)|terminal prompts disabled'
}

VERIFY_OUTPUT=""

verify_credential() {
    local user="$1" pass="$2"
    local encoded_url

    if VERIFY_OUTPUT=$(git_as_user "$user" "$pass" ls-remote --heads "$CLEAN_URL" 2>&1); then
        return 0
    fi

    if ! is_askpass_failure "$VERIFY_OUTPUT"; then
        return 1
    fi

    # Fallback: credentials in the URL. Less private (visible in the process
    # list) but it works where the askpass helper cannot be executed.
    encoded_url="${PROTOCOL}://$(urlencode "$user"):$(urlencode "$pass")@${HOST}${URL_PATH}"

    if VERIFY_OUTPUT=$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
        git -c credential.helper= -c credential.interactive=false \
            ls-remote --heads "$encoded_url" 2>&1); then
        return 0
    fi

    return 1
}

report_unexpected_error() {
    echo ""
    echo "Error: Could not reach '$REMOTE' to verify the credential."
    echo ""
    printf '%s\n' "$VERIFY_OUTPUT" | sed 's/^/  /'
    echo ""
    echo "Tip: check the network/VPN and the remote URL, then run the command again."
}

# --- Is authentication already working? --------------------------------------

echo ""
echo "Remote:  $REMOTE -> $CLEAN_URL"

STORED=$(credential_request | git_quiet credential fill 2>/dev/null)
STORED_USER=$(field_of "$STORED" username)
STORED_PASS=$(field_of "$STORED" password)

if [ -n "$STORED_PASS" ] && [ "$FORCE" -eq 0 ]; then
    printf 'Checking the stored credential for %s ... ' "$HOST"

    if verify_credential "$STORED_USER" "$STORED_PASS"; then
        echo "ok"
        echo ""
        echo "Already authenticated as '${STORED_USER}' — nothing to do."
        HELPERS=$(git config --get-all credential.helper | paste -sd ', ' -)
        if [ -n "$HELPERS" ]; then
            echo "credential.helper: $HELPERS"
        fi
        echo ""
        echo "Tip: run 'lazy git.remember -f' to replace it."
        exit 0
    fi

    echo "failed"

    if ! is_auth_error "$VERIFY_OUTPUT"; then
        report_unexpected_error
        exit 1
    fi

    echo ""
    echo "Warning: The stored credential for '${STORED_USER}' is no longer valid."
elif [ "$FORCE" -eq 1 ]; then
    echo "Force: asking for a new credential."
else
    echo "No credential stored for $HOST yet."
fi

# --- Ask, verify, retry ------------------------------------------------------

# /dev/tty can exist yet be unusable (cron, some CI runners), so try to open it.
if ! { : < /dev/tty; } 2>/dev/null; then
    echo ""
    echo "Error: An interactive terminal is required to enter the credential."
    echo "       Run 'lazy git.remember' directly in a terminal."
    exit 1
fi

DEFAULT_USER="${STORED_USER:-$URL_USER}"

echo ""
case "$HOST" in
    *github*|*gitlab*|*bitbucket*)
        echo "Note: use a personal access token as the password — $HOST rejects account passwords."
        echo ""
        ;;
esac

ATTEMPT=1

while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    if [ "$MAX_ATTEMPTS" -gt 1 ]; then
        echo "Attempt ${ATTEMPT}/${MAX_ATTEMPTS}"
    fi

    if [ -n "$DEFAULT_USER" ]; then
        printf 'Username [%s]: ' "$DEFAULT_USER"
    else
        printf 'Username: '
    fi

    if ! IFS= read -r INPUT_USER < /dev/tty; then
        echo ""
        echo "Cancelled."
        exit 1
    fi

    INPUT_USER="${INPUT_USER:-$DEFAULT_USER}"

    if [ -z "$INPUT_USER" ]; then
        echo "Error: Username must not be empty."
        echo ""
        ATTEMPT=$((ATTEMPT + 1))
        continue
    fi

    printf 'Password / token (hidden): '

    if ! IFS= read -rs INPUT_PASS < /dev/tty; then
        echo ""
        echo "Cancelled."
        exit 1
    fi

    echo ""

    if [ -z "$INPUT_PASS" ]; then
        echo "Error: Password must not be empty."
        echo ""
        ATTEMPT=$((ATTEMPT + 1))
        continue
    fi

    printf 'Verifying against %s ... ' "$HOST"

    if verify_credential "$INPUT_USER" "$INPUT_PASS"; then
        echo "ok"
        break
    fi

    echo "failed"

    if ! is_auth_error "$VERIFY_OUTPUT"; then
        report_unexpected_error
        exit 1
    fi

    echo ""
    echo "Authentication failed — wrong username or password/token."
    echo ""

    DEFAULT_USER="$INPUT_USER"
    ATTEMPT=$((ATTEMPT + 1))

    if [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
        echo "Error: Giving up after ${MAX_ATTEMPTS} attempts. Nothing was saved."
        exit 1
    fi
done

# --- Save --------------------------------------------------------------------

git config --local credential.helper "$HELPER_VALUE"

# `store --file=` is resolved from the worktree root, which is where git runs
# commands from; be explicit so the write lands in the right place.
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ]; then
    cd "$TOPLEVEL" || exit 1
fi

# Drop stale entries for this host before writing the new one.
credential_request | git_store_only credential reject >/dev/null 2>&1

{
    credential_request
    printf 'username=%s\npassword=%s\n\n' "$INPUT_USER" "$INPUT_PASS"
} | git_store_only credential approve

STORE_FILE="${TOPLEVEL:+$TOPLEVEL/}${CREDENTIAL_STORE}"

if [ ! -s "$STORE_FILE" ]; then
    echo ""
    echo "Error: The credential could not be written to $STORE_FILE"
    exit 1
fi

chmod 600 "$STORE_FILE" 2>/dev/null

echo ""
echo "Saved. Git will no longer ask for this repository."
echo "  user:   $INPUT_USER"
echo "  host:   $HOST"
echo "  helper: $HELPER_VALUE"
echo "  file:   $STORE_FILE"
echo ""
echo "The file lives inside .git, so it is never committed."
echo "Remove it with: git config --local --unset credential.helper && rm -f $CREDENTIAL_STORE"
