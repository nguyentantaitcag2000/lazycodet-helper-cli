#!/bin/bash

set -u

usage() {
    echo "Usage:"
    echo "  lazy gpg [encrypted-file]"
    echo ""
    echo "Decrypt a GPG file next to the encrypted file. When no file is given,"
    echo "the command asks for its path. GnuPG securely prompts for a passphrase"
    echo "when the key or encrypted file requires one. If the result is a ZIP,"
    echo "the command can also extract it and let unzip request its password."
    echo ""
    echo "Output names:"
    echo "  report.pdf.gpg  -> report.pdf"
    echo "  archive.pgp     -> archive"
    echo "  secrets.asc     -> secrets"
    echo "  encrypted-file  -> encrypted-file.decrypted"
    echo ""
    echo "The command never overwrites an existing output file."
    echo ""
    echo "Options:"
    echo "  -h, --help      Show this help"
}

FILE_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if [ $# -gt 1 ]; then
                echo "Error: Only one encrypted file is supported." >&2
                exit 1
            fi
            FILE_PATH="${1:-}"
            break
            ;;
        -*)
            echo "Error: Unknown option -> $1" >&2
            echo "" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [ -n "$FILE_PATH" ]; then
                echo "Error: Only one encrypted file is supported." >&2
                exit 1
            fi
            FILE_PATH="$1"
            ;;
    esac
    shift
done

if ! command -v gpg >/dev/null 2>&1; then
    echo "Error: GnuPG is not installed (the 'gpg' command was not found)." >&2
    echo "       Install GnuPG, then run 'lazy gpg' again." >&2
    exit 1
fi

if [ -z "$FILE_PATH" ]; then
    printf 'Encrypted file path: '
    if ! IFS= read -r FILE_PATH || [ -z "$FILE_PATH" ]; then
        echo ""
        echo "Cancelled."
        exit 1
    fi
fi

# Paths copied from a file manager or terminal are often surrounded by quotes.
# Strip one matching pair without evaluating the contents as shell code.
case "$FILE_PATH" in
    \"*\") FILE_PATH="${FILE_PATH:1:${#FILE_PATH}-2}" ;;
    \'*\') FILE_PATH="${FILE_PATH:1:${#FILE_PATH}-2}" ;;
esac

case "$FILE_PATH" in
    "~") FILE_PATH="$HOME" ;;
    "~/"*) FILE_PATH="$HOME/${FILE_PATH:2}" ;;
esac

# A Windows path pasted into Git Bash needs POSIX separators before dirname is
# used to place the decrypted file beside it. cygpath leaves POSIX paths alone.
case "${MSYSTEM:-}:${FILE_PATH}" in
    ?*:[A-Za-z]:\\*|?*:[A-Za-z]:/*)
        if command -v cygpath >/dev/null 2>&1; then
            FILE_PATH="$(cygpath -u "$FILE_PATH")"
        fi
        ;;
esac

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: Encrypted file not found -> $FILE_PATH" >&2
    exit 1
fi

INPUT_DIR="$(dirname "$FILE_PATH")"
INPUT_NAME="${FILE_PATH##*/}"

case "$INPUT_NAME" in
    *.[gG][pP][gG]|*.[pP][gG][pP]|*.[aA][sS][cC])
        OUTPUT_NAME="${INPUT_NAME%????}"
        ;;
    *)
        OUTPUT_NAME="${INPUT_NAME}.decrypted"
        ;;
esac

# A file literally named .gpg has no usable stem.
if [ -z "$OUTPUT_NAME" ]; then
    OUTPUT_NAME="${INPUT_NAME}.decrypted"
fi

OUTPUT_PATH="${INPUT_DIR}/${OUTPUT_NAME}"

if [ -e "$OUTPUT_PATH" ] || [ -L "$OUTPUT_PATH" ]; then
    echo "Error: Output already exists -> $OUTPUT_PATH" >&2
    echo "       Move or rename it first; nothing was overwritten." >&2
    exit 1
fi

# Keep incomplete plaintext private and isolated. The temporary directory is on
# the same filesystem as the destination, so the final move is atomic.
OLD_UMASK="$(umask)"
umask 077
TEMP_DIR="$(mktemp -d "${INPUT_DIR}/.lazy-gpg.XXXXXX")" || {
    umask "$OLD_UMASK"
    echo "Error: Could not create a temporary file beside -> $FILE_PATH" >&2
    exit 1
}
umask "$OLD_UMASK"
TEMP_FILE="${TEMP_DIR}/output"
EXTRACT_TEMP_DIR=""

cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -f "$TEMP_FILE"
        rmdir "$TEMP_DIR" 2>/dev/null || true
    fi

    if [ -n "${EXTRACT_TEMP_DIR:-}" ] && [ -d "$EXTRACT_TEMP_DIR" ]; then
        case "$EXTRACT_TEMP_DIR" in
            "${INPUT_DIR}/.lazy-unzip."*) rm -rf "$EXTRACT_TEMP_DIR" ;;
        esac
    fi
}
trap cleanup EXIT

# Let pinentry use this terminal on systems where GPG_TTY is not already set.
if [ -z "${GPG_TTY:-}" ]; then
    if TERMINAL_PATH="$(tty 2>/dev/null)"; then
        GPG_TTY="$TERMINAL_PATH"
        export GPG_TTY
    fi
fi

echo "Decrypting: $FILE_PATH"
echo "Output:     $OUTPUT_PATH"

if ! gpg --output "$TEMP_FILE" --decrypt "$FILE_PATH"; then
    echo "Error: Decryption failed. No output file was saved." >&2
    exit 1
fi

if [ ! -f "$TEMP_FILE" ]; then
    echo "Error: GnuPG reported success but did not create an output file." >&2
    exit 1
fi

if ! mv -n "$TEMP_FILE" "$OUTPUT_PATH"; then
    echo "Error: Could not save the decrypted file -> $OUTPUT_PATH" >&2
    exit 1
fi

# mv -n deliberately returns success when another process created the output
# after the earlier check. In that case the temp file is still here.
if [ -e "$TEMP_FILE" ]; then
    echo "Error: Output appeared while decrypting -> $OUTPUT_PATH" >&2
    echo "       Nothing was overwritten." >&2
    exit 1
fi

rmdir "$TEMP_DIR"
TEMP_DIR=""

echo "Decrypted successfully:"
echo "  $OUTPUT_PATH"

is_zip_file() {
    local magic

    case "$OUTPUT_NAME" in
        *.[zZ][iI][pP]) return 0 ;;
    esac

    # Also recognize ZIP data whose embedded/original name did not end in .zip.
    # These are the signatures for a normal, empty, or spanned ZIP archive.
    if command -v od >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
        magic="$(od -An -N4 -tx1 "$OUTPUT_PATH" 2>/dev/null | tr -d '[:space:]')"
        case "$magic" in
            504b0304|504b0506|504b0708) return 0 ;;
        esac
    fi

    return 1
}

ask_to_unzip() {
    local answer

    while true; do
        printf 'The decrypted file is a ZIP. Unzip it now? [y/N]: '
        if ! IFS= read -r answer; then
            echo ""
            echo "Skipped extraction."
            return 1
        fi

        case "$answer" in
            y|Y|yes|Yes|YES) return 0 ;;
            ""|n|N|no|No|NO)
                echo "Skipped extraction."
                return 1
                ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

if ! is_zip_file || ! ask_to_unzip; then
    exit 0
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: The decrypted file is a ZIP, but 'unzip' is not installed." >&2
    echo "       The ZIP was kept at: $OUTPUT_PATH" >&2
    exit 1
fi

case "$OUTPUT_NAME" in
    *.[zZ][iI][pP]) EXTRACT_NAME="${OUTPUT_NAME%????}" ;;
    *) EXTRACT_NAME="${OUTPUT_NAME}.unzipped" ;;
esac

if [ -z "$EXTRACT_NAME" ]; then
    EXTRACT_NAME="${OUTPUT_NAME}.unzipped"
fi

EXTRACT_PATH="${INPUT_DIR}/${EXTRACT_NAME}"

if [ -e "$EXTRACT_PATH" ] || [ -L "$EXTRACT_PATH" ]; then
    echo "Error: Extraction destination already exists -> $EXTRACT_PATH" >&2
    echo "       The ZIP was kept and nothing was overwritten." >&2
    exit 1
fi

OLD_UMASK="$(umask)"
umask 077
EXTRACT_TEMP_DIR="$(mktemp -d "${INPUT_DIR}/.lazy-unzip.XXXXXX")" || {
    umask "$OLD_UMASK"
    echo "Error: Could not create a temporary extraction directory." >&2
    echo "       The ZIP was kept at: $OUTPUT_PATH" >&2
    exit 1
}
umask "$OLD_UMASK"
EXTRACT_TEMP_PATH="${EXTRACT_TEMP_DIR}/content"
mkdir "$EXTRACT_TEMP_PATH"

echo "Extracting to: $EXTRACT_PATH"
echo "If this ZIP is password-protected, unzip will ask for its password."

if ! unzip -q "$OUTPUT_PATH" -d "$EXTRACT_TEMP_PATH"; then
    echo "Error: ZIP extraction failed. No extracted directory was saved." >&2
    echo "       The decrypted ZIP is still available at: $OUTPUT_PATH" >&2
    exit 1
fi

if ! mv -n "$EXTRACT_TEMP_PATH" "$EXTRACT_PATH"; then
    echo "Error: Could not save the extracted directory -> $EXTRACT_PATH" >&2
    exit 1
fi

if [ -e "$EXTRACT_TEMP_PATH" ]; then
    echo "Error: Extraction destination appeared while unzip was running." >&2
    echo "       Nothing was overwritten; the ZIP was kept at: $OUTPUT_PATH" >&2
    exit 1
fi

rmdir "$EXTRACT_TEMP_DIR"
EXTRACT_TEMP_DIR=""

echo "Unzipped successfully:"
echo "  $EXTRACT_PATH"
