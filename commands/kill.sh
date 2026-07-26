#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

usage() {
    echo "Usage:"
    echo "  lazy kill <port> [-y]"
    echo ""
    echo "Lists the processes listening on <port> and kills them after confirmation."
    echo ""
    echo "Options:"
    echo "  -y, --yes    Skip the confirmation prompt"
    echo "  -h, --help   Show this help"
}

PORT=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
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

collect_pids_windows() {
    netstat -ano 2>/dev/null |
    awk -v port=":$PORT" '
        $1 !~ /^(TCP|UDP)$/ { next }
        substr($2, length($2) - length(port) + 1) != port { next }
        $NF ~ /^[0-9]+$/ && $NF != "0" { print $NF }
    ' |
    sort -un
}

collect_pids_unix() {
    local pids=""

    if command -v lsof >/dev/null 2>&1; then
        pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null)
    fi

    if [ -z "$pids" ] && command -v ss >/dev/null 2>&1; then
        pids=$(ss -lptn "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]\+' | cut -d= -f2)
    fi

    if [ -z "$pids" ] && command -v fuser >/dev/null 2>&1; then
        pids=$(fuser "$PORT/tcp" 2>/dev/null | tr -s ' ' '\n')
    fi

    if [ -z "$pids" ] && command -v netstat >/dev/null 2>&1; then
        pids=$(
            netstat -lptn 2>/dev/null |
            awk -v port=":$PORT" '
                substr($4, length($4) - length(port) + 1) != port { next }
                { split($NF, a, "/"); if (a[1] ~ /^[0-9]+$/) print a[1] }
            '
        )
    fi

    echo "$pids" | grep -E '^[0-9]+$' | sort -un
}

process_name_windows() {
    local pid="$1"
    local line

    line=$(tasklist //FI "PID eq $pid" //NH //FO CSV 2>/dev/null | head -n 1)

    case "$line" in
        '"'*) echo "$line" | sed 's/^"//; s/".*//' ;;
        *) echo "unknown" ;;
    esac
}

process_name_unix() {
    local pid="$1"
    local name

    name=$(ps -p "$pid" -o comm= 2>/dev/null | head -n 1)
    echo "${name:-unknown}"
}

process_detail_unix() {
    local pid="$1"
    local args

    args=$(ps -p "$pid" -o args= 2>/dev/null | head -n 1)
    echo "$args"
}

kill_windows() {
    local pid="$1"
    taskkill //PID "$pid" //F >/dev/null 2>&1
}

kill_unix() {
    local pid="$1"
    local i

    if ! kill -15 "$pid" 2>/dev/null; then
        return 1
    fi

    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done

    kill -9 "$pid" 2>/dev/null
    sleep 0.2

    if kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    return 0
}

if is_git_bash; then
    PIDS=$(collect_pids_windows)
else
    PIDS=$(collect_pids_unix)
fi

if [ -z "$PIDS" ]; then
    echo "Info: No process is listening on port $PORT."
    exit 0
fi

COUNT=$(echo "$PIDS" | wc -l | tr -d ' ')

echo ""
echo "Processes on port $PORT:"
echo ""
printf "  %-8s %s\n" "PID" "NAME"

while read -r pid; do
    [ -z "$pid" ] && continue

    if is_git_bash; then
        name=$(process_name_windows "$pid")
    else
        name=$(process_name_unix "$pid")
        detail=$(process_detail_unix "$pid")
        if [ -n "$detail" ]; then
            name="$name  ($(echo "$detail" | cut -c1-60))"
        fi
    fi

    printf "  %-8s %s\n" "$pid" "$name"
done <<< "$PIDS"

echo ""

if [ "$ASSUME_YES" -eq 0 ]; then
    printf "Kill %s process(es) on port %s? [y/N] " "$COUNT" "$PORT"

    ANSWER=""

    # Read from stdin so `echo y | lazy kill <port>` works; fall back to the
    # terminal when stdin is closed or redirected from /dev/null.
    if ! read -r ANSWER; then
        if ! { read -r ANSWER < /dev/tty; } 2>/dev/null; then
            echo ""
            echo "Error: No input available for confirmation. Use -y to skip the prompt."
            exit 1
        fi
    fi

    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

FAILED=0

while read -r pid; do
    [ -z "$pid" ] && continue

    if is_git_bash; then
        killer=kill_windows
    else
        killer=kill_unix
    fi

    if "$killer" "$pid"; then
        echo "Killed $pid"
    else
        echo "Failed to kill $pid"
        FAILED=$((FAILED + 1))
    fi
done <<< "$PIDS"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "Warning: $FAILED process(es) could not be killed (try running with higher privileges)."
    exit 1
fi

echo ""
echo "Port $PORT is free."
