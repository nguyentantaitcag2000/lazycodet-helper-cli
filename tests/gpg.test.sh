#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${SCRIPT_DIR}/../commands/gpg.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazy-gpg-test.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/lazy-gpg-test.*) rm -rf "$TEST_ROOT" ;;
        *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_has() {
    grep -qF -- "$2" <<<"$1" || fail "expected output to contain: $2"
}

MOCK_BIN="${TEST_ROOT}/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "${MOCK_BIN}/gpg" <<'EOF'
#!/bin/bash
set -u

printf '%s\n' "$@" >> "$LAZY_GPG_TEST_LOG"

output=""
input=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --decrypt) input="$2"; shift 2 ;;
        *) exit 90 ;;
    esac
done

if [ "${LAZY_GPG_TEST_FAIL:-0}" = "1" ]; then
    echo "mock: bad passphrase" >&2
    exit 2
fi

printf 'decrypted %s\n' "$input" > "$output"
EOF
chmod +x "${MOCK_BIN}/gpg"

GPG_LOG="${TEST_ROOT}/gpg.log"
export LAZY_GPG_TEST_LOG="$GPG_LOG"

HELP_OUTPUT="$(bash "$COMMAND" --help)"
assert_has "$HELP_OUTPUT" "lazy gpg [encrypted-file]"
assert_has "$HELP_OUTPUT" "never overwrites"

EMPTY_BIN="${TEST_ROOT}/empty-bin"
mkdir -p "$EMPTY_BIN"
if PATH="$EMPTY_BIN" /bin/bash "$COMMAND" ignored.gpg >"${TEST_ROOT}/missing-gpg.log" 2>&1; then
    fail "a missing gpg executable should fail"
fi
grep -qF "GnuPG is not installed" "${TEST_ROOT}/missing-gpg.log" || fail "missing gpg was not explained"

INPUT_DIR="${TEST_ROOT}/files with spaces"
mkdir -p "$INPUT_DIR"
INPUT_FILE="${INPUT_DIR}/report final.pdf.gpg"
printf 'ciphertext\n' > "$INPUT_FILE"

RUN_OUTPUT="$(PATH="${MOCK_BIN}:$PATH" bash "$COMMAND" "$INPUT_FILE" 2>&1)"
OUTPUT_FILE="${INPUT_DIR}/report final.pdf"
[ -f "$OUTPUT_FILE" ] || fail "the decrypted file was not written beside its input"
grep -qF "decrypted $INPUT_FILE" "$OUTPUT_FILE" || fail "gpg output was not preserved"
assert_has "$RUN_OUTPUT" "Decrypted successfully:"
assert_has "$RUN_OUTPUT" "$OUTPUT_FILE"
grep -qxF -- "--decrypt" "$GPG_LOG" || fail "gpg was not called in decrypt mode"
grep -qxF -- "$INPUT_FILE" "$GPG_LOG" || fail "gpg did not receive the exact input path"

# Interactive mode accepts a quoted pasted path and removes the known suffix.
ARMORED_FILE="${INPUT_DIR}/secrets.ASC"
printf 'ciphertext\n' > "$ARMORED_FILE"
PROMPT_OUTPUT="$(
    printf "'%s'\n" "$ARMORED_FILE" |
        PATH="${MOCK_BIN}:$PATH" bash "$COMMAND" 2>&1
)"
[ -f "${INPUT_DIR}/secrets" ] || fail "interactive mode did not create the expected output"
assert_has "$PROMPT_OUTPUT" "Encrypted file path:"

# Unknown suffixes get an explicit .decrypted suffix.
UNKNOWN_FILE="${INPUT_DIR}/payload.bin"
printf 'ciphertext\n' > "$UNKNOWN_FILE"
PATH="${MOCK_BIN}:$PATH" bash "$COMMAND" "$UNKNOWN_FILE" >/dev/null
[ -f "${UNKNOWN_FILE}.decrypted" ] || fail "unknown suffix did not use .decrypted"

# Existing plaintext must be preserved without invoking gpg again.
CONFLICT_INPUT="${INPUT_DIR}/keep.txt.gpg"
CONFLICT_OUTPUT="${INPUT_DIR}/keep.txt"
printf 'ciphertext\n' > "$CONFLICT_INPUT"
printf 'keep me\n' > "$CONFLICT_OUTPUT"
CALLS_BEFORE="$(wc -l < "$GPG_LOG")"
if PATH="${MOCK_BIN}:$PATH" bash "$COMMAND" "$CONFLICT_INPUT" >"${TEST_ROOT}/conflict.log" 2>&1; then
    fail "existing output should have stopped decryption"
fi
CALLS_AFTER="$(wc -l < "$GPG_LOG")"
[ "$CALLS_BEFORE" -eq "$CALLS_AFTER" ] || fail "gpg ran despite an existing output"
grep -qxF 'keep me' "$CONFLICT_OUTPUT" || fail "existing output was changed"
grep -qF "nothing was overwritten" "${TEST_ROOT}/conflict.log" || fail "conflict was not explained"

# A failed passphrase/decryption leaves neither plaintext nor temporary files.
FAILED_INPUT="${INPUT_DIR}/private.txt.gpg"
FAILED_OUTPUT="${INPUT_DIR}/private.txt"
printf 'ciphertext\n' > "$FAILED_INPUT"
if LAZY_GPG_TEST_FAIL=1 PATH="${MOCK_BIN}:$PATH" bash "$COMMAND" "$FAILED_INPUT" >"${TEST_ROOT}/failed.log" 2>&1; then
    fail "gpg failure should be returned to the caller"
fi
[ ! -e "$FAILED_OUTPUT" ] || fail "failed decryption left a plaintext file"
if find "$INPUT_DIR" -maxdepth 1 -name '.lazy-gpg.*' | grep -q .; then
    fail "failed decryption left a temporary directory"
fi
grep -qF "No output file was saved" "${TEST_ROOT}/failed.log" || fail "failure was not explained"

if PATH="${MOCK_BIN}:$PATH" bash "$COMMAND" "${INPUT_DIR}/missing.gpg" >"${TEST_ROOT}/missing.log" 2>&1; then
    fail "a missing input file should fail"
fi
grep -qF "Encrypted file not found" "${TEST_ROOT}/missing.log" || fail "missing input was not explained"

echo "gpg tests passed"
