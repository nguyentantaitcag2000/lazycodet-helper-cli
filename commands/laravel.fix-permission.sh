#!/bin/bash
#
# lazy laravel.fix-permission — make a Laravel project's writable directories
# (storage/ and bootstrap/cache/) writable by both you and the PHP process,
# without leaving Git-visible mode changes behind.
#
# The usual fixes (`chmod -R 775`, `chmod -R a+rwX`, `chmod -R 777`) either put
# the execute bit on plain files, which Git reports as a mode change on every
# tracked .gitignore, or only fix the files that exist today: the next log file
# created by `docker exec ... php artisan` (root) or by php-fpm (www-data, 0644)
# is unwritable for the other side again. This command sets:
#
#   directories  2775  setgid, so new files inherit the PHP group
#   files         664  never executable (tracked executables in HEAD excepted)
#   owner:group        you : the group the PHP process runs as
#   default ACL        you and that group get rw on every file created later

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

# Relative to the Laravel root. Both ship with Laravel and are the only paths
# the framework itself writes to.
TARGETS=("storage" "bootstrap/cache")

# Process names that can write to storage/. nginx is left out on purpose: it
# shares the project mount with php-fpm but never writes into storage/.
PHP_PROCESS_REGEX='^(php|php-fpm.*|php[0-9.]+|php-fpm[0-9.]+|frankenphp|httpd|apache2|rr|swoole.*|octane.*)$'

usage() {
    echo "Usage:"
    echo "  lazy laravel.fix-permission [path] [--check] [-y]"
    echo "                              [--owner <user>] [--group <group|gid>] [--container <name>]"
    echo ""
    echo "Makes storage/ and bootstrap/cache/ writable by you and by the PHP process"
    echo "(php-fpm, Apache, artisan in a container), for the files that exist now and"
    echo "for every file created later, without adding Git-visible mode changes."
    echo ""
    echo "Arguments:"
    echo "  path                 Laravel project, or a directory above it (default: .)"
    echo ""
    echo "Options:"
    echo "      --check          Report what is wrong, change nothing (exit 1 if anything is)"
    echo "  -y, --yes            Apply without asking for confirmation"
    echo "      --owner <user>   Owner of the files (default: you, or \$SUDO_USER under sudo)"
    echo "      --group <group>  Group PHP runs as, name or numeric gid (default: detected)"
    echo "      --container <n>  Read the PHP group from this Docker container"
    echo "  -h, --help           Show this help"
}

START_DIR=""
CHECK_ONLY=0
ASSUME_YES=0
OPT_OWNER=""
OPT_GROUP=""
OPT_CONTAINER=""

need_value() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: Option '$1' needs a value."
        echo ""
        usage
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --owner) need_value "$@"; OPT_OWNER="$2"; shift ;;
        --group) need_value "$@"; OPT_GROUP="$2"; shift ;;
        --container) need_value "$@"; OPT_CONTAINER="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1"; echo ""; usage; exit 1 ;;
        *)
            if [ -n "$START_DIR" ]; then
                echo "Error: Only one path is supported."
                exit 1
            fi
            START_DIR="$1"
            ;;
    esac
    shift
done

START_DIR="${START_DIR:-.}"

if [ ! -d "$START_DIR" ]; then
    echo "Error: Not a directory -> $START_DIR"
    exit 1
fi

# --- Locate the Laravel root --------------------------------------------------

is_laravel_root() {
    [ -f "$1/artisan" ] && [ -f "$1/bootstrap/app.php" ]
}

# Upwards first (running from inside the project), then a shallow search down
# (running from a monorepo root that holds the API in a subdirectory).
find_laravel_root() {
    local dir
    local found=()
    local candidate

    dir="$(cd -P "$1" && pwd)"
    while :; do
        if is_laravel_root "$dir"; then
            printf '%s' "$dir"
            return 0
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done

    while IFS= read -r -d '' candidate; do
        candidate="$(dirname "$candidate")"
        if is_laravel_root "$candidate"; then
            found+=("$candidate")
        fi
    done < <(find "$(cd -P "$1" && pwd)" -maxdepth 4 \
        \( -name vendor -o -name node_modules -o -name .git \) -prune -o \
        -type f -name artisan -print0 2>/dev/null)

    if [ "${#found[@]}" -eq 1 ]; then
        printf '%s' "${found[0]}"
        return 0
    fi

    if [ "${#found[@]}" -gt 1 ]; then
        echo "Error: Several Laravel projects were found below $(cd -P "$1" && pwd):" >&2
        for candidate in "${found[@]}"; do
            echo "  $candidate" >&2
        done
        echo "Pass the one to fix: lazy laravel.fix-permission <path>" >&2
        return 2
    fi

    echo "Error: No Laravel project (artisan + bootstrap/app.php) at or below $(cd -P "$1" && pwd)." >&2
    return 1
}

ROOT="$(find_laravel_root "$START_DIR")" || exit 1

for target in "${TARGETS[@]}"; do
    if [ ! -d "$ROOT/$target" ]; then
        echo "Error: $ROOT/$target does not exist. Is this a complete Laravel checkout?"
        exit 1
    fi
done

# --- Filesystem --------------------------------------------------------------

# A Windows drive seen from WSL (drvfs/9p) or any other mount without POSIX
# ownership ignores chown and fakes the mode bits: nothing here would stick.
FS_TYPE="$(stat -f -c %T "$ROOT/storage" 2>/dev/null || echo unknown)"
case "$FS_TYPE" in
    v9fs|9p|fuseblk|vfat|msdos|exfat|ntfs|smb2|cifs)
        echo "Error: $ROOT is on a '$FS_TYPE' filesystem."
        echo "       It has no real Unix ownership or permissions, so chmod/chown cannot fix"
        echo "       anything here. Move the project into the Linux filesystem (e.g. ~/code)"
        echo "       and run this command there."
        exit 1
        ;;
esac

# --- Owner -------------------------------------------------------------------

resolve_owner() {
    if [ -n "$OPT_OWNER" ]; then
        printf '%s' "$OPT_OWNER"
    elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        printf '%s' "$SUDO_USER"
    elif [ "$(id -u)" = "0" ]; then
        # Root with no sudo trail (e.g. a root shell): the checkout's own owner is
        # the person who edits it.
        stat -c %U "$ROOT/artisan"
    else
        id -un
    fi
}

OWNER="$(resolve_owner)"
if ! id -u "$OWNER" >/dev/null 2>&1; then
    echo "Error: Unknown user -> $OWNER"
    exit 1
fi

# --- Group PHP runs as -------------------------------------------------------

GROUP_GID=""
GROUP_SOURCE=""

group_name() {
    getent group "$1" 2>/dev/null | cut -d: -f1
}

# Most frequent non-root gid among PHP-looking processes in "gid comm" lines.
# The php-fpm master runs as root; its workers are the ones that write files.
pick_php_gid() {
    awk -v re="$PHP_PROCESS_REGEX" '
        NF >= 2 && $1 ~ /^[0-9]+$/ && $1 != "0" {
            comm = $2
            sub(/.*\//, "", comm)
            sub(/:$/, "", comm)
            if (comm ~ re) count[$1]++
        }
        END {
            best = ""
            for (gid in count) if (best == "" || count[gid] > count[best]) best = gid
            if (best != "") print best
        }'
}

# Real path of every mount source of a container, one per line.
container_mount_sources() {
    docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$1" 2>/dev/null
}

container_mounts_root() {
    local source
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        case "$ROOT/storage/" in
            "$source"/*) return 0 ;;
        esac
    done < <(container_mount_sources "$1")
    return 1
}

container_php_gid() {
    # docker top runs ps on the host, so it works even when the image has no ps,
    # and reports the numeric ids the kernel checks against the bind mount.
    # The pid column is mandatory for docker top; it is dropped before counting.
    docker top "$1" -eo pid,gid,comm 2>/dev/null | tail -n +2 | awk '{ print $2, $3 }' | pick_php_gid
}

detect_group_from_docker() {
    local id
    local name
    local gid

    command -v docker >/dev/null 2>&1 || return 1

    if [ -n "$OPT_CONTAINER" ]; then
        gid="$(container_php_gid "$OPT_CONTAINER")"
        if [ -z "$gid" ]; then
            echo "Error: No running PHP process was found in container '$OPT_CONTAINER'." >&2
            exit 1
        fi
        GROUP_GID="$gid"
        GROUP_SOURCE="PHP processes in container '$OPT_CONTAINER'"
        return 0
    fi

    while IFS= read -r id; do
        [ -n "$id" ] || continue
        container_mounts_root "$id" || continue
        gid="$(container_php_gid "$id")"
        [ -n "$gid" ] || continue
        name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null)"
        GROUP_GID="$gid"
        GROUP_SOURCE="PHP processes in container '${name#/}', which mounts this project"
        return 0
    done < <(docker ps -q 2>/dev/null)

    return 1
}

# On Linux and WSL the host's ps also lists every container's processes. Those
# belong to their own projects, so only processes outside a container count.
host_php_processes() {
    local pid
    local gid
    local comm

    while read -r pid gid comm; do
        if grep -qE 'docker|containerd|kubepods|libpod|lxc' "/proc/${pid}/cgroup" 2>/dev/null; then
            continue
        fi
        printf '%s %s\n' "$gid" "$comm"
    done < <(ps -eo pid=,gid=,comm= 2>/dev/null)
}

detect_group_from_host() {
    local gid
    gid="$(host_php_processes | pick_php_gid)"
    [ -n "$gid" ] || return 1
    GROUP_GID="$gid"
    GROUP_SOURCE="PHP processes running on this machine"
}

resolve_group() {
    if [ -n "$OPT_GROUP" ]; then
        case "$OPT_GROUP" in
            *[!0-9]*)
                GROUP_GID="$(getent group "$OPT_GROUP" 2>/dev/null | cut -d: -f3)"
                if [ -z "$GROUP_GID" ]; then
                    echo "Error: Unknown group -> $OPT_GROUP"
                    exit 1
                fi
                ;;
            *) GROUP_GID="$OPT_GROUP" ;;
        esac
        GROUP_SOURCE="--group"
        return 0
    fi

    if [ -n "$OPT_CONTAINER" ] && ! command -v docker >/dev/null 2>&1; then
        echo "Error: --container needs the docker CLI, which is not installed."
        exit 1
    fi

    detect_group_from_docker && return 0
    detect_group_from_host && return 0

    # Nothing is running: `php artisan serve` or tests run as you, so your own
    # group is the one that needs access.
    GROUP_GID="$(id -g "$OWNER")"
    GROUP_SOURCE="no PHP process found, using ${OWNER}'s own group (pass --group to override)"
}

resolve_group

GROUP_LABEL="$(group_name "$GROUP_GID")"
GROUP_LABEL="${GROUP_LABEL:-gid $GROUP_GID}"
OWNER_UID="$(id -u "$OWNER")"

HAS_ACL=0
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
    HAS_ACL=1
fi

# --- Tracked executables -----------------------------------------------------

# Files that HEAD records as executable keep their x bit; everything else loses
# it. HEAD rather than the index: a stray chmod that was already staged must not
# be taken as the intended mode.
KEEP_EXEC_FILE="$(mktemp "${TMPDIR:-/tmp}/lazy-laravel-perm.XXXXXX")"
trap 'rm -f -- "$KEEP_EXEC_FILE"' EXIT

if git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    git -C "$ROOT" ls-tree -r -z HEAD -- "${TARGETS[@]}" 2>/dev/null \
        | tr '\0' '\n' \
        | awk -F'\t' '$1 ~ /^100755 / { print $2 }' > "$KEEP_EXEC_FILE"
fi

is_kept_exec() {
    grep -qxF -- "$1" "$KEEP_EXEC_FILE"
}

# --- Inspection --------------------------------------------------------------

in_targets() {
    (cd "$ROOT" && find "${TARGETS[@]}" "$@" 2>/dev/null)
}

count_lines() {
    if [ -z "$1" ]; then
        echo 0
    else
        printf '%s\n' "$1" | wc -l | tr -d ' '
    fi
}

ISSUES=0
REPORT=()

add_issue() {
    local count="$1"
    local text="$2"
    local sample="$3"

    [ "$count" -gt 0 ] || return 0
    ISSUES=$((ISSUES + count))
    REPORT+=("$(printf '%5s  %s' "$count" "$text")")
    if [ -n "$sample" ]; then
        REPORT+=("$(printf '%s\n' "$sample" | head -n 3 | sed 's/^/         e.g. /')")
    fi
}

inspect() {
    local list
    local unexpected_exec=""
    local path
    local missing_acl=""
    local dir
    local acl

    ISSUES=0
    REPORT=()

    # With a default ACL, a file PHP creates later stays owned by PHP but carries
    # an rw entry for you, so ownership only matters when there is no ACL.
    if [ "$HAS_ACL" -eq 0 ]; then
        list="$(in_targets ! -user "$OWNER_UID")"
        add_issue "$(count_lines "$list")" "not owned by $OWNER" "$list"
    fi

    list="$(in_targets ! -group "$GROUP_GID")"
    add_issue "$(count_lines "$list")" "not in group $GROUP_LABEL" "$list"

    list="$(in_targets -type d ! -perm -2775)"
    add_issue "$(count_lines "$list")" "directories not 2775 (setgid + group-writable)" "$list"

    list="$(in_targets -type f ! -perm -0660)"
    add_issue "$(count_lines "$list")" "files not readable+writable by owner and group" "$list"

    list="$(in_targets -perm -0002 ! -type l)"
    add_issue "$(count_lines "$list")" "world-writable" "$list"

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        is_kept_exec "$path" && continue
        unexpected_exec="${unexpected_exec}${path}"$'\n'
    done < <(in_targets -type f -perm /0111)
    unexpected_exec="${unexpected_exec%$'\n'}"
    add_issue "$(count_lines "$unexpected_exec")" "files with an execute bit (shows up as a Git mode change)" "$unexpected_exec"

    if [ "$HAS_ACL" -eq 1 ]; then
        while IFS= read -r dir; do
            [ -n "$dir" ] || continue
            acl="$(cd "$ROOT" && getfacl -dpcn -- "$dir" 2>/dev/null)"
            if ! printf '%s\n' "$acl" | grep -q "^user:${OWNER_UID}:rw" \
                || ! printf '%s\n' "$acl" | grep -q "^group:${GROUP_GID}:rw"; then
                missing_acl="${missing_acl}${dir}"$'\n'
            fi
        done < <(in_targets -type d)
        missing_acl="${missing_acl%$'\n'}"
        add_issue "$(count_lines "$missing_acl")" "directories without the default ACL for files created later" "$missing_acl"
    fi
}

print_report() {
    local line
    for line in ${REPORT[@]+"${REPORT[@]}"}; do
        printf '%s\n' "$line"
    done
}

# --- Summary -----------------------------------------------------------------

echo "Project:  $ROOT"
echo "Paths:    ${TARGETS[*]}"
echo "Owner:    $OWNER"
echo "Group:    $GROUP_LABEL  ($GROUP_SOURCE)"
if [ "$HAS_ACL" -eq 1 ]; then
    echo "ACL:      default ACL for $OWNER and $GROUP_LABEL on every directory"
else
    echo "ACL:      unavailable (setfacl is not installed)"
fi
echo ""

inspect

if [ "$ISSUES" -eq 0 ]; then
    echo "Everything is already in order."
    FIXED_NOTHING=1
else
    echo "Found:"
    print_report
    echo ""
    FIXED_NOTHING=0
fi

acl_install_hint() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "  sudo apt-get install acl"
    elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install acl"
    elif command -v yum >/dev/null 2>&1; then
        echo "  sudo yum install acl"
    elif command -v apk >/dev/null 2>&1; then
        echo "  sudo apk add acl"
    elif command -v pacman >/dev/null 2>&1; then
        echo "  sudo pacman -S acl"
    elif command -v zypper >/dev/null 2>&1; then
        echo "  sudo zypper install acl"
    else
        echo "  install the 'acl' package with your package manager"
    fi
}

# Without a default ACL, a log file created later is only as open as the mode
# Laravel creates it with. Monolog's own default leaves it 0644.
logging_hint() {
    local config="$ROOT/config/logging.php"

    [ "$HAS_ACL" -eq 0 ] || return 0

    echo "Note: without ACLs, files created from now on get the creator's umask (usually 644),"
    echo "      so the next laravel-*.log may again be writable by only one side. Either"
    echo "      install ACL support and run this command again:"
    acl_install_hint
    if [ -f "$config" ] && ! grep -q "'permission'" "$config"; then
        echo "      or give the log channels an explicit mode in config/logging.php:"
        echo "        'daily' => [ ..., 'permission' => 0664 ],"
        echo "        'single' => [ ..., 'permission' => 0664 ],"
    fi
    echo ""
}

git_hint() {
    local staged

    git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    staged="$(git -C "$ROOT" diff --cached --summary -- "${TARGETS[@]}" 2>/dev/null | grep -c 'mode change' || true)"
    if [ "${staged:-0}" -gt 0 ]; then
        echo "Note: $staged mode change(s) under these paths are staged in Git. Unstage them with:"
        echo "  git -C \"$ROOT\" restore --staged -- ${TARGETS[*]}"
        echo ""
    fi
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    logging_hint
    git_hint
    [ "$FIXED_NOTHING" -eq 1 ] && exit 0
    echo "Run without --check to fix."
    exit 1
fi

if [ "$FIXED_NOTHING" -eq 1 ]; then
    logging_hint
    git_hint
    exit 0
fi

# --- Privileges --------------------------------------------------------------

# chown to another user, chgrp to a group you are not in, and chmod on a file
# someone else owns all need root. Plain `sudo` only when one of them applies.
needs_root() {
    [ "$(id -u)" = "0" ] && return 1
    [ "$OWNER_UID" != "$(id -u)" ] && return 0
    case " $(id -G) " in
        *" $GROUP_GID "*) ;;
        *) return 0 ;;
    esac
    [ -n "$(in_targets ! -user "$(id -u)" -print -quit)" ] && return 0
    return 1
}

RUN=()
if needs_root; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: Fixing this needs root, and sudo is not available. Run it as root."
        exit 1
    fi
    RUN=(sudo)
    echo "This needs root (files owned by someone else, or a group you are not in); sudo will ask."
    echo ""
fi

has_tty() {
    { : < /dev/tty; } 2>/dev/null
}

if [ "$ASSUME_YES" -ne 1 ]; then
    if ! has_tty; then
        echo "Error: Confirmation needs an interactive terminal. Re-run with -y to apply."
        exit 1
    fi
    printf 'Apply these permissions? [y/N] '
    read -r answer < /dev/tty || answer=""
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled. Nothing was changed."; exit 1 ;;
    esac
    echo ""
fi

# --- Apply -------------------------------------------------------------------

run_in_root() {
    (cd "$ROOT" && ${RUN[@]+"${RUN[@]}"} "$@")
}

step() {
    printf '  %s\n' "$1"
}

echo "Applying:"

# -P never follows symlinks (storage/app/public is linked from public/storage the
# other way round, but a project may add its own).
step "chown -R $OWNER:$GROUP_LABEL"
run_in_root chown -R -P "$OWNER_UID:$GROUP_GID" "${TARGETS[@]}" || exit 1

step "directories -> 2775"
run_in_root find "${TARGETS[@]}" -type d -exec chmod 2775 {} + || exit 1

step "files -> 664"
run_in_root find "${TARGETS[@]}" -type f -exec chmod 664 {} + || exit 1

if [ -s "$KEEP_EXEC_FILE" ]; then
    step "files tracked as executable in HEAD -> 775"
    while IFS= read -r path; do
        [ -f "$ROOT/$path" ] || continue
        run_in_root chmod 775 -- "$path" || exit 1
    done < "$KEEP_EXEC_FILE"
fi

if [ "$HAS_ACL" -eq 1 ]; then
    step "ACL: $OWNER and $GROUP_LABEL rw on existing files, inherited by new ones"
    # Access ACL on what exists, default ACL on directories. X grants execute
    # only to directories, so files stay non-executable and Git stays quiet.
    ACL_SPEC="u:${OWNER_UID}:rwX,g:${GROUP_GID}:rwX"
    if ! run_in_root setfacl -R -P -m "$ACL_SPEC" "${TARGETS[@]}" 2>/dev/null \
        || ! run_in_root find "${TARGETS[@]}" -type d \
            -exec setfacl -d -m "u::rwX,g::rwX,o::rX,${ACL_SPEC}" {} + 2>/dev/null; then
        echo ""
        echo "Warning: this filesystem rejected the ACLs ($FS_TYPE). Existing files are fixed,"
        echo "         but files created later fall back to the creator's umask."
        HAS_ACL=0
    fi
fi

echo ""

inspect
if [ "$ISSUES" -eq 0 ]; then
    echo "Done. You and $GROUP_LABEL can both write to ${TARGETS[*]}."
else
    echo "Some entries could not be fixed:"
    print_report
fi
echo ""

logging_hint
git_hint

[ "$ISSUES" -eq 0 ]
