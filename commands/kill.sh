#!/bin/bash
# Kill whatever holds a TCP port: in this OS, in another WSL distro, or on the
# Windows host.
#
# WSL2 runs every distro inside one VM with a shared network namespace but
# separate PID namespaces. A port bound in distro A is therefore genuinely
# taken for distro B, while distro B's own ss/lsof see the socket with no owner
# attached. That "the port is in use but there is nothing here to kill" case is
# what the cross-distro scan resolves.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

usage() {
    echo "Usage:"
    echo "  lazy kill <port> [-y] [--list] [--local | --wsl --host | --all]"
    echo ""
    echo "Lists what is listening on <port> and kills it after confirmation."
    echo ""
    echo "Only this machine is searched to begin with. When the port turns out to be"
    echo "held from outside it - another WSL distro, or the Windows host - the search"
    echo "widens on its own and asks again before touching anything out there."
    echo ""
    echo "Options:"
    echo "  -y, --yes    Skip every confirmation prompt"
    echo "      --list   Only report what holds the port, kill nothing"
    echo "      --local  Never look outside this machine"
    echo "      --wsl    Always search the other running WSL distros"
    echo "      --host   Always search the Windows host"
    echo "  -a, --all    Same as --wsl --host"
    echo "  -h, --help   Show this help"
}

PORT=""
ASSUME_YES=0
LIST_ONLY=0
# -1 = decide from what the local scan finds, 0 = never, 1 = always
WANT_WSL=-1
WANT_HOST=-1

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --list) LIST_ONLY=1 ;;
        --local) WANT_WSL=0; WANT_HOST=0 ;;
        --wsl) WANT_WSL=1 ;;
        --host) WANT_HOST=1 ;;
        -a|--all) WANT_WSL=1; WANT_HOST=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1"; echo ""; usage; exit 1 ;;
        *)
            if [ -n "$PORT" ]; then
                echo "Error: Only one port is supported."
                exit 1
            fi
            PORT="$1"
            ;;
    esac
    shift
done

if [ -z "$PORT" ]; then
    usage
    exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Error: Invalid port -> $PORT (expected 1-65535)"
    exit 1
fi

c_bold=""; c_dim=""; c_warn=""; c_err=""; c_reset=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$'\033[1m'; c_dim=$'\033[2m'
    c_warn=$'\033[33m'; c_err=$'\033[31m'; c_reset=$'\033[0m'
fi

say_warn() { printf '  %s%s%s\n' "$c_warn" "$1" "$c_reset"; }
say_dim()  { printf '  %s%s%s\n' "$c_dim" "$1" "$c_reset"; }
say_err()  { printf '%sError: %s%s\n' "$c_err" "$1" "$c_reset" >&2; }

# --------------------------------------------------------------- linux worker
#
# One script, two modes, run both here and (over wsl.exe) inside other distros,
# so every distro is inspected and cleaned up by exactly the same code.
#
# probe mode prints:
#   HOLD|<kind>|<pid>|<addr>|<name>|<detail>|<container>
#   CONT|<id>|<name>|<project>
#   FREE=yes|no
# kind is proc (an ordinary process), container (a published Docker port) or
# orphan (the socket exists but its owner lives in another PID namespace).
#
# kill mode reads LAZY_PIDS / LAZY_CONTAINERS and prints:
#   KILLED|<pid>   STOPPED|<container>   FAILED|<what>   FREE=yes|no
linux_worker() {
    cat <<'LAZY_WORKER'
set -u

port="$LAZY_PORT"

# Most listeners worth killing are root-owned, and without privileges ss hides
# their pid - which looks exactly like a socket owned by another distro. Only
# non-interactive sudo is used, so no password prompt can appear mid-scan.
SUDO=""
if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
fi

TAB="$(printf '\t')"

# Ground truth for "is this port bound at all", straight from the kernel with
# no tool to install. State 0A is TCP_LISTEN.
socket_exists() {
    awk -v hp="$(printf '%04X' "$port")" '
        $4 == "0A" { split($2, a, ":"); if (a[2] == hp) found = 1 }
        END { exit !found }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# "<pid>\t<addr>\t<name>", pid "-" when the socket has no owner we can see.
listeners() {
    if command -v ss >/dev/null 2>&1; then
        $SUDO ss -ltnp 2>/dev/null | awk -v port="$port" '
            $1 != "LISTEN" { next }
            {
                addr = $4
                suffix = ":" port
                if (length(addr) < length(suffix)) next
                if (substr(addr, length(addr) - length(suffix) + 1) != suffix) next

                rest = $0
                found = 0
                while (match(rest, /\("[^"]+",pid=[0-9]+/)) {
                    s = substr(rest, RSTART, RLENGTH)
                    name = s; sub(/^\("/, "", name); sub(/",pid=[0-9]+$/, "", name)
                    pid = s; sub(/^.*pid=/, "", pid)
                    print pid "\t" addr "\t" name
                    rest = substr(rest, RSTART + RLENGTH)
                    found = 1
                }
                if (found == 0) print "-\t" addr "\t-"
            }
        '
        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
        $SUDO lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null |
            awk 'NR > 1 && $2 ~ /^[0-9]+$/ { print $2 "\t" $9 "\t" $1 }'
        return 0
    fi

    if command -v netstat >/dev/null 2>&1; then
        $SUDO netstat -ltnp 2>/dev/null | awk -v port="$port" '
            $1 !~ /^tcp/ { next }
            {
                addr = $4
                suffix = ":" port
                if (length(addr) < length(suffix)) next
                if (substr(addr, length(addr) - length(suffix) + 1) != suffix) next
                split($NF, a, "/")
                if (a[1] ~ /^[0-9]+$/) print a[1] "\t" addr "\t" a[2]
            }
        '
        return 0
    fi

    if command -v fuser >/dev/null 2>&1; then
        $SUDO fuser "$port/tcp" 2>/dev/null | tr -s ' ' '\n' |
            grep -E '^[0-9]+$' |
            while read -r p; do
                printf '%s\t*:%s\t%s\n' "$p" "$port" \
                    "$(ps -p "$p" -o comm= 2>/dev/null | head -1)"
            done
        return 0
    fi

    return 0
}

# Containers publishing this host port. Only one can, so the first row wins.
container_rows() {
    command -v docker >/dev/null 2>&1 || return 0
    $SUDO docker ps \
        --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.Ports}}' \
        2>/dev/null |
        awk -F'|' -v pat=":$port->" 'index($4, pat) > 0 { print $1 "|" $2 "|" $3 }'
}

# A published Docker port is not held by the container itself but by the
# userland forwarder in front of it, named differently per Docker flavour.
is_port_forwarder() {
    case "$1" in
        docker-proxy|docker-pr*|rootlesskit*|slirp4netns*|exe) return 0 ;;
    esac
    return 1
}

probe() {
    rows=""
    cont="$(container_rows | head -1)"
    cid=""; cname=""; cproj=""

    if [ -n "$cont" ]; then
        cid="$(printf '%s' "$cont" | cut -d'|' -f1)"
        cname="$(printf '%s' "$cont" | cut -d'|' -f2)"
        cproj="$(printf '%s' "$cont" | cut -d'|' -f3)"
        printf 'CONT|%s|%s|%s\n' "$cid" "$cname" "$cproj"
    fi

    rows="$(listeners)"
    found=0

    while IFS="$TAB" read -r pid addr name; do
        [ -n "$addr" ] || continue
        found=1
        [ -n "$name" ] || name="-"

        if [ "$pid" = "-" ]; then
            printf 'HOLD|orphan|-|%s|-|-|-\n' "$addr"
        elif [ -n "$cid" ] && is_port_forwarder "$name"; then
            if [ -n "$cproj" ]; then
                printf 'HOLD|container|%s|%s|%s|%s (compose project %s)|%s\n' \
                    "$pid" "$addr" "$name" "$cname" "$cproj" "$cid"
            else
                printf 'HOLD|container|%s|%s|%s|%s|%s\n' \
                    "$pid" "$addr" "$name" "$cname" "$cid"
            fi
        else
            cmd="$(ps -p "$pid" -o args= 2>/dev/null | head -1 | tr '|' ' ' | cut -c1-58)"
            printf 'HOLD|proc|%s|%s|%s|%s|-\n' "$pid" "$addr" "$name" "${cmd:--}"
        fi
    done <<ROWS_END
$rows
ROWS_END

    # Nothing could be attributed, yet the kernel says the port is bound: that
    # is the cross-namespace case, so report it instead of "port is free".
    if [ "$found" -eq 0 ] && socket_exists; then
        printf 'HOLD|orphan|-|*:%s|-|-|-\n' "$port"
    fi
}

stop_containers() {
    for c in $LAZY_CONTAINERS; do
        [ -n "$c" ] || continue
        if $SUDO docker stop "$c" >/dev/null 2>&1; then
            printf 'STOPPED|%s\n' "$c"
        else
            printf 'FAILED|container %s\n' "$c"
        fi
    done
}

kill_pids() {
    for pid in $LAZY_PIDS; do
        [ -n "$pid" ] || continue

        # The process group first: dev servers leave child listeners behind.
        $SUDO kill -15 "-$pid" 2>/dev/null ||
            $SUDO kill -15 "$pid" 2>/dev/null || {
                printf 'FAILED|%s\n' "$pid"
                continue
            }

        i=0
        while [ "$i" -lt 10 ]; do
            $SUDO kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
            i=$((i + 1))
        done

        if $SUDO kill -0 "$pid" 2>/dev/null; then
            $SUDO kill -9 "-$pid" 2>/dev/null || $SUDO kill -9 "$pid" 2>/dev/null
            sleep 0.3
        fi

        if $SUDO kill -0 "$pid" 2>/dev/null; then
            printf 'FAILED|%s\n' "$pid"
        else
            printf 'KILLED|%s\n' "$pid"
        fi
    done
}

case "$LAZY_MODE" in
    probe)
        probe
        ;;
    kill)
        stop_containers
        kill_pids
        i=0
        while [ "$i" -lt 10 ]; do
            socket_exists || break
            sleep 0.2
            i=$((i + 1))
        done
        ;;
esac

if socket_exists; then
    echo "FREE=no"
else
    echo "FREE=yes"
fi
LAZY_WORKER
}

# Prefix the worker with its inputs so nothing has to survive an env whitelist
# or a quoting round trip through wsl.exe.
worker_input() {
    local mode="$1"
    local pids="${2:-}"
    local containers="${3:-}"

    printf 'LAZY_PORT=%s\n' "$PORT"
    printf 'LAZY_MODE=%s\n' "$mode"
    printf 'LAZY_PIDS="%s"\n' "$pids"
    printf 'LAZY_CONTAINERS="%s"\n' "$containers"
    linux_worker
}

# Keep only the worker's own line prefixes: wsl.exe mixes in notices of its
# own, such as the systemd user-session warning it prints for -u root.
worker_output() {
    tr -d '\r' | grep -E '^(HOLD\||CONT\||KILLED\||STOPPED\||FAILED\||FREE=)'
}

run_worker_local() {
    worker_input "$@" | bash -s 2>/dev/null | worker_output
}

# ------------------------------------------------------------------- wsl side

WSL_EXE=""
WSL_STATE=""
INTEROP_NOTE=""

# wsl.exe is reachable both from Git Bash (on PATH) and from inside a distro
# (through interop), which is what lets one distro clean up another.
wsl_available() {
    case "$WSL_STATE" in
        ok) return 0 ;;
        no) return 1 ;;
    esac

    WSL_STATE=no

    if is_git_bash; then
        WSL_EXE="$(command -v wsl.exe 2>/dev/null || true)"
        [ -n "$WSL_EXE" ] || return 1
        WSL_STATE=ok
        return 0
    fi

    is_wsl || return 1

    # systemd-binfmt wipes the WSLInterop registration on some images, which
    # breaks every .exe call with "Exec format error". Put it back for this
    # boot; the report says so and prints how to make it permanent.
    if ! wsl_interop_ok; then
        if wsl_enable_interop; then
            INTEROP_NOTE=re-registered
        else
            INTEROP_NOTE=broken
            return 1
        fi
    fi

    WSL_EXE="$(win_exe_path wsl.exe || true)"
    [ -n "$WSL_EXE" ] || return 1
    WSL_STATE=ok
    return 0
}

# wsl.exe still writes UTF-16LE on builds that ignore WSL_UTF8, and command
# substitution drops the NUL bytes before we could notice, so go via a file.
list_running_distros() {
    local tmp raw

    tmp="$(mktemp "${TMPDIR:-/tmp}/lazy-wsl-list.XXXXXX")" || return 1
    WSL_UTF8=1 "$WSL_EXE" -l -q --running > "$tmp" 2>/dev/null </dev/null

    if LC_ALL=C tr -d '\000' < "$tmp" | cmp -s - "$tmp"; then
        raw="$(cat "$tmp")"
    else
        raw="$(iconv -f UTF-16LE -t UTF-8 < "$tmp" 2>/dev/null || tr -d '\000' < "$tmp")"
    fi

    rm -f "$tmp"
    printf '%s\n' "$raw" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

# -u root: docker-proxy and most service listeners are root-owned, so pid
# attribution needs it. MSYS_NO_PATHCONV keeps Git Bash from rewriting the
# arguments into C:\ paths on the way in.
run_worker_in_distro() {
    local distro="$1"
    shift

    if is_git_bash; then
        worker_input "$@" |
            MSYS_NO_PATHCONV=1 "$WSL_EXE" -d "$distro" -u root -- bash -s 2>&1 |
            worker_output
    else
        worker_input "$@" |
            "$WSL_EXE" -d "$distro" -u root -- bash -s 2>&1 |
            worker_output
    fi
}

# ------------------------------------------------------------------ host side

HOST_NETSTAT=""; HOST_TASKLIST=""; HOST_TASKKILL=""
HOST_STATE=""

host_available() {
    case "$HOST_STATE" in
        ok) return 0 ;;
        no) return 1 ;;
    esac

    HOST_STATE=no

    if is_git_bash; then
        HOST_NETSTAT="$(command -v netstat 2>/dev/null || true)"
        HOST_TASKLIST="$(command -v tasklist 2>/dev/null || true)"
        HOST_TASKKILL="$(command -v taskkill 2>/dev/null || true)"
    else
        is_wsl || return 1
        wsl_available || return 1
        HOST_NETSTAT="$(win_exe_path netstat.exe || true)"
        HOST_TASKLIST="$(win_exe_path tasklist.exe || true)"
        HOST_TASKKILL="$(win_exe_path taskkill.exe || true)"
    fi

    [ -n "$HOST_NETSTAT" ] || return 1
    HOST_STATE=ok
    return 0
}

# "<pid>|<addr>" for LISTENING sockets on PORT, covering 0.0.0.0, 127.0.0.1,
# [::] and [::1]. That last one is what Nuxt and Vite bind when host is
# "localhost", and the usual reason a port looks free but refuses to bind.
host_listeners() {
    "$HOST_NETSTAT" -ano 2>/dev/null </dev/null | tr -d '\r' |
    awk -v port="$PORT" '
        BEGIN { suffix = ":" port }
        $1 != "TCP" { next }
        $4 != "LISTENING" { next }
        {
            addr = $2
            pid = $NF
            if (length(addr) < length(suffix)) next
            if (substr(addr, length(addr) - length(suffix) + 1) != suffix) next
            if (pid !~ /^[0-9]+$/ || pid == "0") next
            print pid "|" addr
        }
    '
}

host_process_name() {
    local pid="$1"
    local line

    [ -n "$HOST_TASKLIST" ] || { echo "unknown"; return; }

    line="$("$HOST_TASKLIST" "$(win_flag FI)" "PID eq $pid" "$(win_flag NH)" \
            "$(win_flag FO)" CSV 2>/dev/null </dev/null | tr -d '\r' | head -n 1)"

    case "$line" in
        '"'*) printf '%s\n' "$line" | sed 's/^"//; s/".*//' ;;
        *) echo "unknown" ;;
    esac
}

# Processes that only relay somebody else's port, or that Windows will not let
# go of. Killing them breaks far more than the port, and for the relays the
# real owner sits inside a distro - which is what the WSL scan reaches.
host_protection_hint() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        wslrelay.exe|wslhost.exe|wslservice.exe|wsl.exe|vmmem|vmmemwsl)
            echo "WSL port forwarder, the real owner is inside a distro" ;;
        com.docker.backend.exe|com.docker.proxy.exe|vpnkit.exe|dockerd.exe)
            echo "Docker Desktop, stop the container instead" ;;
        system|idle|registry)
            echo "Windows kernel (http.sys on 80/443), try: net stop http" ;;
        svchost.exe)
            echo "Windows service host, stop the owning service instead" ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------- row buffer

ROWS="$(mktemp "${TMPDIR:-/tmp}/lazy-kill-rows.XXXXXX")" || exit 1
trap 'rm -f "$ROWS" "${ROWS}.keep"' EXIT

# scope|target|kind|pid|addr|name|detail|container
add_row() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$ROWS"
}

rows_where() {
    awk -F'|' -v scope="$1" -v kind="$2" \
        '(scope == "" || $1 == scope) && (kind == "" || $3 == kind)' "$ROWS"
}

# Fold one worker probe into the buffer under a scope/target label.
ingest_probe() {
    local scope="$1" target="$2" probe="$3"
    local line kind pid addr name detail container

    while IFS='|' read -r tag kind pid addr name detail container; do
        [ "$tag" = "HOLD" ] || continue
        add_row "$scope" "$target" "$kind" "$pid" "$addr" "$name" "$detail" "$container"
    done <<PROBE_END
$probe
PROBE_END
}

# Windows rows, used both as the local scan under Git Bash and as the host scan
# from inside WSL.
ingest_host() {
    local scope="$1" target="$2"
    local line pid addr name hint

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pid="${line%%|*}"
        addr="${line#*|}"
        name="$(host_process_name "$pid")"

        if hint="$(host_protection_hint "$name")"; then
            add_row "$scope" "$target" protected "$pid" "$addr" "$name" "$hint" "-"
        else
            add_row "$scope" "$target" proc "$pid" "$addr" "$name" "-" "-"
        fi
    done <<HOST_END
$(host_listeners)
HOST_END
}

# ---------------------------------------------------------------------- scans

# Two scopes are killed through the Windows tools ("host") and two through the
# Linux worker ("local", "wsl"). Under Git Bash this machine *is* the host, so
# the local scan files its rows under "host" and the kill path follows.
if is_git_bash; then
    HERE_SCOPE="host"
    HERE_LABEL="windows host"
elif is_wsl; then
    HERE_SCOPE="local"
    HERE_LABEL="this distro (${WSL_DISTRO_NAME:-current})"
else
    HERE_SCOPE="local"
    HERE_LABEL="this machine"
fi

scan_here() {
    if is_git_bash; then
        host_available || return 0
        ingest_host "$HERE_SCOPE" "$HERE_LABEL"
        return 0
    fi

    ingest_probe "$HERE_SCOPE" "$HERE_LABEL" "$(run_worker_local probe)"
}

scan_other_distros() {
    local distro probe

    while IFS= read -r distro; do
        [ -n "$distro" ] || continue
        # Skip ourselves, and never wake a stopped distro: --running already
        # limits the list, and a distro that is not running holds no port.
        [ "$distro" = "${WSL_DISTRO_NAME:-}" ] && continue
        probe="$(run_worker_in_distro "$distro" probe)"
        [ -n "$probe" ] || continue
        ingest_probe wsl "$distro" "$probe"
    done <<DISTRO_END
$(list_running_distros)
DISTRO_END
}

scan_here

# --------------------------------------------------------- how wide to search

# A killable owner right here and nothing unexplained left over: no reason to
# look further. Otherwise widen, because "nothing to kill" is precisely the
# report that sends people distro-hopping by hand.
HERE_OWNERS="$(rows_where "$HERE_SCOPE" proc; rows_where "$HERE_SCOPE" container)"
HERE_ORPHANS="$(rows_where "$HERE_SCOPE" orphan)"
HERE_RELAYS="$(rows_where "$HERE_SCOPE" protected)"

NEEDS_WIDENING=0
if [ -z "$HERE_OWNERS" ] || [ -n "$HERE_ORPHANS" ] || [ -n "$HERE_RELAYS" ]; then
    NEEDS_WIDENING=1
fi

DO_WSL=0
DO_HOST=0

case "$WANT_WSL" in
    1) DO_WSL=1 ;;
    -1) [ "$NEEDS_WIDENING" -eq 1 ] && DO_WSL=1 ;;
esac

case "$WANT_HOST" in
    1) DO_HOST=1 ;;
    -1) [ "$NEEDS_WIDENING" -eq 1 ] && DO_HOST=1 ;;
esac

# Under Git Bash the host was already covered by the local scan.
if [ "$HERE_SCOPE" = "host" ]; then
    DO_HOST=0
fi

if [ "$DO_WSL" -eq 1 ]; then
    if wsl_available; then
        scan_other_distros
    elif [ "$WANT_WSL" -eq 1 ]; then
        say_err "Cannot reach the other WSL distros from here."
    fi
fi

if [ "$DO_HOST" -eq 1 ]; then
    if host_available; then
        ingest_host host "windows host"
    elif [ "$WANT_HOST" -eq 1 ]; then
        say_err "Cannot reach the Windows host from here."
    fi
fi

# An orphan row is the near side of a socket that another scope has now
# attributed properly; keeping both would list the same listener twice.
if [ -n "$(rows_where "" proc)$(rows_where "" container)" ]; then
    if grep -v '^[^|]*|[^|]*|orphan|' "$ROWS" > "${ROWS}.keep"; then
        mv -f "${ROWS}.keep" "$ROWS"
    fi
fi

# --------------------------------------------------------------------- report

if [ ! -s "$ROWS" ]; then
    echo "Info: No process is listening on port $PORT."
    exit 0
fi

echo ""
printf '%sWhat holds port %s:%s\n' "$c_bold" "$PORT" "$c_reset"
echo ""
printf '  %-26s %-8s %-22s %s\n' "WHERE" "PID" "ADDRESS" "WHAT"

while IFS='|' read -r scope target kind pid addr name detail container; do
    [ -n "$scope" ] || continue

    if [ "$scope" = "wsl" ]; then
        where="wsl: $target"
    else
        where="$target"
    fi

    case "$kind" in
        container) what="container $detail" ;;
        orphan) what="bound here but owned elsewhere in the WSL VM" ;;
        protected) what="$name  [skipped: $detail]" ;;
        *)
            what="$name"
            [ "$detail" = "-" ] || what="$name  ($detail)"
            ;;
    esac

    printf '  %-26s %-8s %-22s %s\n' "$where" "$pid" "$addr" "$what"
done < "$ROWS"

echo ""

case "$INTEROP_NOTE" in
    re-registered)
        say_dim "Windows interop was off in this distro; re-registered it for this session."
        say_dim "To keep it after a restart:"
        say_dim "$(wsl_interop_permanent_hint)"
        echo ""
        ;;
    broken)
        say_warn "Windows interop is off in this distro, so other distros and the Windows"
        say_warn "host cannot be reached. Enable it with:"
        say_warn "  echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /proc/sys/fs/binfmt_misc/register"
        echo ""
        ;;
esac

# ---------------------------------------------------------------------- kills

# Split the decision: everything reachable through Linux is one question, the
# Windows host is a second one, because killing a Windows service is a much
# bigger hammer than killing a dev server.
NEAR_ROWS="$(awk -F'|' '$1 != "host" && ($3 == "proc" || $3 == "container")' "$ROWS")"
HOST_ROWS="$(awk -F'|' '$1 == "host" && $3 == "proc"' "$ROWS")"

if [ -n "$(rows_where "" protected)" ]; then
    say_dim "Rows marked [skipped] are left alone on purpose - see the note on each."
    echo ""
fi

if [ -z "$NEAR_ROWS" ] && [ -z "$HOST_ROWS" ]; then
    say_warn "Nothing here can be killed safely."
    exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    exit 0
fi

confirm() {
    local prompt="$1"
    local answer=""

    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi

    printf '%s [y/N] ' "$prompt"

    # Read from stdin so `echo y | lazy kill <port>` works; fall back to the
    # terminal when stdin is closed or redirected from /dev/null.
    if ! read -r answer; then
        if ! { read -r answer < /dev/tty; } 2>/dev/null; then
            echo ""
            say_err "No input available for confirmation. Use -y to skip the prompt."
            exit 1
        fi
    fi

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
    esac
    return 1
}

FAILED=0
KILLED_ANY=0

# The worker only knows ids and pids; the report already knows what they are,
# so name them back from the buffer instead of echoing raw ids at the user.
row_label() {
    awk -F'|' -v field="$1" -v want="$2" '
        $field == want {
            if ($3 == "container") { print $7; exit }
            print $6; exit
        }
    ' "$ROWS"
}

kill_linux_targets() {
    local pairs scope target pids containers result line what label

    pairs="$(awk -F'|' '$1 != "host" && ($3 == "proc" || $3 == "container") \
        { print $1 "|" $2 }' "$ROWS" | sort -u)"

    while IFS='|' read -r scope target; do
        [ -n "$scope" ] || continue

        # A container holds the port through a forwarder, so stopping the
        # container is what actually frees it - and `docker start` undoes it.
        containers="$(awk -F'|' -v s="$scope" -v t="$target" \
            '$1 == s && $2 == t && $3 == "container" && $8 != "-" { print $8 }' "$ROWS" |
            sort -u | tr '\n' ' ')"
        pids="$(awk -F'|' -v s="$scope" -v t="$target" \
            '$1 == s && $2 == t && $3 == "proc" { print $4 }' "$ROWS" |
            sort -u | tr '\n' ' ')"

        if [ "$scope" = "local" ]; then
            result="$(run_worker_local kill "$pids" "$containers")"
        else
            result="$(run_worker_in_distro "$target" kill "$pids" "$containers")"
        fi

        while IFS= read -r line; do
            case "$line" in
                KILLED\|*)
                    what="${line#KILLED|}"
                    label="$(row_label 4 "$what")"
                    echo "Killed $what ${label:+($label) }in ${target} (process tree)"
                    KILLED_ANY=1 ;;
                STOPPED\|*)
                    what="${line#STOPPED|}"
                    label="$(row_label 8 "$what")"
                    echo "Stopped container ${label:-$what} in ${target}"
                    KILLED_ANY=1 ;;
                FAILED\|*)
                    echo "Failed: ${line#FAILED|} in ${target}"
                    FAILED=$((FAILED + 1)) ;;
            esac
        done <<RESULT_END
$result
RESULT_END
    done <<PAIRS_END
$pairs
PAIRS_END
}

kill_host_targets() {
    local pid name

    # One process listening on both stacks is two rows but a single taskkill;
    # running it twice would report the second call as a failure.
    while IFS='|' read -r pid name; do
        [ -n "$pid" ] || continue
        if "$HOST_TASKKILL" "$(win_flag PID)" "$pid" \
            "$(win_flag T)" "$(win_flag F)" >/dev/null 2>&1 </dev/null
        then
            echo "Killed $pid ($name, process tree) on the Windows host"
            KILLED_ANY=1
        else
            echo "Failed to kill $pid ($name) on the Windows host"
            FAILED=$((FAILED + 1))
        fi
    done <<HOSTKILL_END
$(printf '%s\n' "$HOST_ROWS" | awk -F'|' 'NF { print $4 "|" $6 }' | sort -u)
HOSTKILL_END
}

# Count what will actually be acted on, not how many sockets were listed: one
# container publishing both stacks is two rows but a single `docker stop`.
count_actions() {
    awk -F'|' '
        $3 == "container" && $8 != "-" { print "c\t" $8; next }
        $3 == "proc" { print "p\t" $1 "\t" $2 "\t" $4 }
    ' | sort -u | grep -c . || true
}

if [ -n "$NEAR_ROWS" ]; then
    NEAR_COUNT="$(printf '%s\n' "$NEAR_ROWS" | count_actions)"
    OUTSIDE_COUNT="$(printf '%s\n' "$NEAR_ROWS" | awk -F'|' '$1 == "wsl"' | count_actions)"

    if [ "$OUTSIDE_COUNT" -gt 0 ]; then
        NEAR_PROMPT="Kill $NEAR_COUNT target(s), $OUTSIDE_COUNT of them in another WSL distro?"
    else
        NEAR_PROMPT="Kill $NEAR_COUNT target(s) on port $PORT?"
    fi

    if confirm "$NEAR_PROMPT"; then
        kill_linux_targets
    else
        echo "Left the WSL/Linux targets alone."
    fi
    echo ""
fi

if [ -n "$HOST_ROWS" ]; then
    HOST_COUNT="$(printf '%s\n' "$HOST_ROWS" | count_actions)"

    if [ -n "$NEAR_ROWS" ]; then
        HOST_PROMPT="Also kill $HOST_COUNT process(es) on the Windows host?"
    else
        HOST_PROMPT="Kill $HOST_COUNT process(es) on the Windows host?"
    fi

    if confirm "$HOST_PROMPT"; then
        kill_host_targets
    else
        echo "Left the Windows host alone."
    fi
    echo ""
fi

# -------------------------------------------------------------------- verdict

if [ "$KILLED_ANY" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    echo "Nothing was killed."
    exit 0
fi

if [ "$FAILED" -gt 0 ]; then
    say_warn "$FAILED target(s) could not be killed (try again with higher privileges)."
fi

STILL=""

# The WSL VM shares one network namespace, so a local probe also reflects a
# listener that was just stopped in another distro.
if [ "$HERE_SCOPE" = "local" ]; then
    STILL="$(run_worker_local probe | grep '^HOLD|' || true)"
fi

# Windows keeps its own network stack, so a host kill has to be verified there
# rather than inferred from the Linux side.
if [ -z "$STILL" ] && { [ "$HERE_SCOPE" = "host" ] || [ -n "$HOST_ROWS" ]; }; then
    if host_available; then
        STILL="$(host_listeners)"
    fi
fi

if [ -z "$STILL" ]; then
    echo "Port $PORT is free."
    exit 0
fi

echo ""
say_warn "Port $PORT is still in use. Run the command again to see who holds it now."
exit 1
