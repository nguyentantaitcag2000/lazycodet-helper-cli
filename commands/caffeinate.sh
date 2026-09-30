#!/bin/bash
# List the caffeinate processes keeping this Mac awake, and stop them.
#
# macOS drops a sleep assertion when the process holding it exits, so a
# caffeinate left behind by an interrupted session keeps the machine awake with
# nothing on screen to explain why. Two tools each hold half the answer:
# `pmset -g assertions` knows what every assertion actually blocks and how many
# seconds it has left, while `ps` knows when the process started and who started
# it. This command joins them into one list and can stop any of them.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/platform.sh
source "${SCRIPT_DIR}/../lib/platform.sh"

usage() {
    echo "Usage:"
    echo "  lazy caffeinate [--list] [--kill <pid>] [--kill-all] [-y]"
    echo ""
    echo "Lists every caffeinate process preventing this Mac from sleeping, with"
    echo "when it started, how much of its timeout is left, what it is holding"
    echo "awake, and which process started it."
    echo ""
    echo "With no option it opens an interactive list with a key menu at the"
    echo "bottom. Without a terminal it behaves like --list."
    echo ""
    echo "Options:"
    echo "      --list       Print the list and exit, never interactive"
    echo "      --kill <pid> Stop one listed caffeinate"
    echo "      --kill-all   Stop every listed caffeinate"
    echo "  -y, --yes        Skip the confirmation prompt"
    echo "  -h, --help       Show this help"
}

MODE=""
KILL_PID=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list) MODE=list ;;
        --kill-all) MODE=kill-all ;;
        --kill)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --kill needs a pid." >&2
                exit 1
            fi
            MODE=kill-one
            KILL_PID="$1"
            ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: Unknown option -> $1" >&2; echo ""; usage; exit 1 ;;
        *) echo "Error: Unexpected argument -> $1" >&2; echo ""; usage; exit 1 ;;
    esac
    shift
done

if [ -n "$KILL_PID" ] && ! [[ "$KILL_PID" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid pid -> $KILL_PID" >&2
    exit 1
fi

# The test hooks below feed recorded ps/pmset output so the parsing can be
# exercised on any platform. Without them this is macOS-only: caffeinate and
# pmset are macOS tools, and lazy.sh already refuses the command elsewhere.
USING_FIXTURES=0
if [ -n "${LAZY_TEST_PS_FILE:-}" ] || [ -n "${LAZY_TEST_PMSET_FILE:-}" ]; then
    USING_FIXTURES=1
fi

if [ "$USING_FIXTURES" -eq 0 ] && ! is_macos; then
    echo "Error: 'lazy caffeinate' is only available on macOS." >&2
    exit 1
fi

c_bold=""; c_dim=""; c_warn=""; c_err=""; c_ok=""; c_reset=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_bold=$'\033[1m'; c_dim=$'\033[2m'
    c_warn=$'\033[33m'; c_err=$'\033[31m'; c_ok=$'\033[32m'; c_reset=$'\033[0m'
fi

INTERACTIVE=0
if [ -z "$MODE" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        INTERACTIVE=1
    else
        MODE=list
    fi
fi

ps_source() {
    if [ -n "${LAZY_TEST_PS_FILE:-}" ]; then
        cat "$LAZY_TEST_PS_FILE"
    else
        ps -axo pid=,ppid=,user=,lstart=,etime=,comm=,args= 2>/dev/null
    fi
}

pmset_source() {
    if [ -n "${LAZY_TEST_PMSET_FILE:-}" ]; then
        cat "$LAZY_TEST_PMSET_FILE"
    else
        pmset -g assertions 2>/dev/null
    fi
}

term_cols() {
    local cols=""

    if [ -t 1 ]; then
        cols="$(tput cols 2>/dev/null || true)"
    fi
    [ -n "$cols" ] || cols="${COLUMNS:-}"
    case "$cols" in
        ''|*[!0-9]*) cols=100 ;;
    esac
    [ "$cols" -ge 60 ] || cols=60
    printf '%s' "$cols"
}

COLS="$(term_cols)"
# Everything before COMMAND is fixed width, so the command gets what is left.
CMD_WIDTH=$((COLS - 62))
[ "$CMD_WIDTH" -ge 20 ] || CMD_WIDTH=20

ROWS="$(mktemp "${TMPDIR:-/tmp}/lazy-caffeinate.XXXXXX")" || exit 1

# ------------------------------------------------------------------ collector
#
# One awk pass over both tools. pmset comes first, then a marker, then ps, so a
# single script can join them without temporary files per source.
#
# Row: elapsed_secs|pid|ppid|user|started|running|remaining|mask|behalf|parent|args
build_rows() {
    {
        pmset_source
        printf '%s\n' '@@@PROCS@@@'
        ps_source
    } | awk -v today_mon="$(date '+%b')" \
            -v today_day="$(date '+%d')" \
            -v today_year="$(date '+%Y')" '
    function human(s,   d, h, m) {
        if (s < 0) s = 0
        if (s >= 86400) { d = int(s / 86400); h = int((s % 86400) / 3600); return d "d " h "h" }
        if (s >= 3600) { h = int(s / 3600); m = int((s % 3600) / 60); return h "h " m "m" }
        if (s >= 60)   { m = int(s / 60); return m "m " (s % 60) "s" }
        return s "s"
    }
    # ps prints elapsed time as [[dd-]hh:]mm:ss.
    function etime_secs(e,   d, p, n, s) {
        d = 0
        if (index(e, "-") > 0) { split(e, p, "-"); d = p[1] + 0; e = p[2] }
        n = split(e, p, ":")
        if (n == 3) s = p[1] * 3600 + p[2] * 60 + p[3]
        else if (n == 2) s = p[1] * 60 + p[2]
        else s = p[1] + 0
        return d * 86400 + s
    }
    function base(p,   n, a) { n = split(p, a, "/"); return a[n] }

    BEGIN { mode = "assert"; cur = ""; cnt = 0 }

    $0 == "@@@PROCS@@@" { mode = "procs"; next }

    mode == "assert" {
        # Reset the owning process on EVERY "pid N(name):" header, not only on
        # caffeinate ones. Skipping that reset makes the detail lines of the
        # next owner - WindowServer has its own "Timeout will fire in" - get
        # charged to the last caffeinate seen, which silently reports a wrong
        # remaining time.
        if ($0 ~ /^[[:space:]]*pid [0-9]+\(/) {
            cur = ""
            owner = $2
            if (owner ~ /\(caffeinate\):$/) {
                cur = owner
                sub(/\(caffeinate\):$/, "", cur)
                seen[cur] = 1
                for (i = 1; i <= NF; i++) {
                    if ($i == "PreventUserIdleDisplaySleep") hd[cur] = 1
                    else if ($i == "PreventUserIdleSystemSleep") hi[cur] = 1
                    else if ($i == "PreventDiskIdle") hm[cur] = 1
                    else if ($i == "PreventSystemSleep") hs[cur] = 1
                    else if ($i == "UserIsActive") hu[cur] = 1
                }
            }
            next
        }

        if (cur == "") next

        if ($0 ~ /asserting for [0-9]+ secs/) {
            for (i = 1; i <= NF; i++) if ($i == "for") total[cur] = $(i + 1) + 0
        }
        if ($0 ~ /asserting on behalf of /) {
            s = $0
            sub(/^.*on behalf of /, "", s)
            gsub(/\|/, " ", s)
            behalf[cur] = s
        }
        # A caffeinate holds several assertions that expire together; take the
        # largest so a rounding difference between them cannot understate it.
        if ($0 ~ /Timeout will fire in [0-9]+ secs/) {
            for (i = 1; i <= NF; i++) {
                if ($i == "in") {
                    v = $(i + 1) + 0
                    if (!(cur in left) || v > left[cur]) left[cur] = v
                }
            }
        }
        next
    }

    mode == "procs" {
        if (NF < 11) next

        pid = $1
        a = ""
        for (i = 11; i <= NF; i++) a = a (a == "" ? "" : " ") $i
        gsub(/\|/, " ", a)
        allargs[pid] = a

        # comm is the executable, so the shell that merely has the word
        # "caffeinate" inside its -c string is correctly left out. Matching on
        # the full command line instead is what makes `pgrep -f caffeinate`
        # report a wrapper shell as if it were holding the machine awake.
        if (base($10) != "caffeinate") next

        cnt++
        cpid[cnt] = pid; cppid[cnt] = $2; cuser[cnt] = $3
        cmon[cnt] = $5; cday[cnt] = $6; cclock[cnt] = $7; cyear[cnt] = $8
        cetime[cnt] = $9
        next
    }

    END {
        for (j = 1; j <= cnt; j++) {
            pid = cpid[j]
            elapsed = etime_secs(cetime[j])
            args = allargs[pid]

            # -t from the command line is the declared total; pmset repeats it
            # and is preferred because it reflects what the kernel accepted.
            tot = 0
            n = split(args, av, " ")
            for (i = 1; i <= n; i++) {
                if (av[i] == "-t" && i < n) tot = av[i + 1] + 0
                else if (av[i] ~ /^-t[0-9]+$/) tot = substr(av[i], 3) + 0
            }
            if (pid in total && total[pid] > 0) tot = total[pid]

            if (pid in left) rem = human(left[pid])
            else if (tot > 0) rem = human(tot - elapsed)
            else if (pid in behalf) rem = "until it ends"
            else rem = "no timeout"

            if (pid in seen)
                mask = (hd[pid] ? "D" : ".") (hi[pid] ? "I" : ".") (hm[pid] ? "M" : ".") \
                       (hs[pid] ? "S" : ".") (hu[pid] ? "U" : ".")
            else
                mask = "-----"

            if (cmon[j] == today_mon && sprintf("%02d", cday[j] + 0) == today_day && cyear[j] == today_year)
                started = "today " cclock[j]
            else
                started = sprintf("%s %02d %s", cmon[j], cday[j] + 0, substr(cclock[j], 1, 5))

            parent = ""
            if (cppid[j] != "1" && (cppid[j] in allargs)) parent = allargs[cppid[j]]

            printf "%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", \
                elapsed, pid, cppid[j], cuser[j], started, human(elapsed), \
                rem, mask, (pid in behalf ? behalf[pid] : ""), parent, args
        }
    }' | sort -t'|' -k1,1nr
}

reload_rows() {
    build_rows > "$ROWS"
}

row_count() {
    local n
    n="$(grep -c . "$ROWS" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

row_at() {
    sed -n "${1}p" "$ROWS"
}

# ------------------------------------------------------------------- renderer

shorten() {
    local text="$1"
    local width="$2"

    if [ "${#text}" -le "$width" ]; then
        printf '%s' "$text"
    else
        printf '%s...' "${text:0:$((width - 3))}"
    fi
}

print_table() {
    local n
    local i=0
    local pid ppid user started running remaining mask behalf parent args

    n="$(row_count)"

    if [ "$n" -eq 0 ]; then
        printf '  %sNothing is holding this Mac awake. It can sleep normally.%s\n' \
            "$c_ok" "$c_reset"
        return
    fi

    if [ "$n" -eq 1 ]; then
        printf '  %s1 caffeinate is keeping this Mac awake.%s\n' "$c_bold" "$c_reset"
    else
        printf '  %s%s caffeinate processes are keeping this Mac awake.%s\n' \
            "$c_bold" "$n" "$c_reset"
    fi
    echo ""

    printf '  %s%-2s %-7s %-16s %-9s %-14s %-6s %s%s\n' \
        "$c_dim" "#" "PID" "STARTED" "RUNNING" "REMAINING" "HOLDS" "COMMAND" "$c_reset"

    while IFS='|' read -r _ pid ppid user started running remaining mask behalf parent args; do
        [ -n "$pid" ] || continue
        i=$((i + 1))

        # Nothing bounds this one, which is the case worth noticing. Colour and
        # padding are applied separately: escapes have no printed width, so
        # letting printf pad a coloured string would skew the columns.
        local rem_color=""
        local rem_end=""
        if [ "$remaining" = "no timeout" ]; then
            rem_color="$c_warn"
            rem_end="$c_reset"
        fi

        printf '  %-2s %-7s %-16s %-9s %s%s%s%*s %-6s %s\n' \
            "$i" "$pid" "$started" "$running" \
            "$rem_color" "$remaining" "$rem_end" \
            "$((14 - ${#remaining}))" "" \
            "$mask" "$(shorten "$args" "$CMD_WIDTH")"

        if [ -n "$behalf" ]; then
            printf '     %s\\_ wrapping %s - stopping caffeinate does not stop it%s\n' \
                "$c_dim" "$(shorten "$behalf" $((CMD_WIDTH + 20)))" "$c_reset"
        elif [ "$ppid" = "1" ]; then
            printf '     %s\\_ orphaned - whatever started it has already exited%s\n' \
                "$c_dim" "$c_reset"
        elif [ -n "$parent" ]; then
            printf '     %s\\_ started by %s: %s%s\n' \
                "$c_dim" "$ppid" "$(shorten "$parent" $((CMD_WIDTH + 10)))" "$c_reset"
        fi

        if [ "$user" != "$(id -un)" ]; then
            printf '     %s\\_ owned by %s - stopping it needs sudo%s\n' \
                "$c_dim" "$user" "$c_reset"
        fi
    done < "$ROWS"

    echo ""
    printf '  %sHOLDS: the caffeinate flags actually in force -%s\n' "$c_dim" "$c_reset"
    printf '  %sD display  I idle system  M disk  S system  U user-active  . not held%s\n' \
        "$c_dim" "$c_reset"
}

# --------------------------------------------------------------------- killing

CAN_SUDO=-1

sudo_ready() {
    if [ "$CAN_SUDO" -eq -1 ]; then
        CAN_SUDO=0
        if [ "$(id -u)" = "0" ]; then
            CAN_SUDO=1
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            CAN_SUDO=2
        fi
    fi
    [ "$CAN_SUDO" -ne 0 ]
}

# Only ever called with a pid this command listed, and never through pkill:
# matching caffeinate by command line would also match the shell that spawned
# it, and could match this script.
signal_pid() {
    local sig="$1"
    local pid="$2"

    if [ "$CAN_SUDO" -eq 2 ]; then
        sudo -n kill "-$sig" "$pid" 2>/dev/null
    else
        kill "-$sig" "$pid" 2>/dev/null
    fi
}

alive() {
    if [ "$CAN_SUDO" -eq 2 ]; then
        sudo -n kill -0 "$1" 2>/dev/null
    else
        kill -0 "$1" 2>/dev/null
    fi
}

# Prints one "<state>|<pid>|<detail>" line. SIGTERM first so caffeinate can
# release its assertions itself; SIGKILL only if it will not go.
stop_pid() {
    local pid="$1"
    local user="$2"
    local i=0

    CAN_SUDO=-1
    if [ "$user" != "$(id -un)" ] && ! sudo_ready; then
        printf 'skipped|%s|owned by %s, run with sudo to stop it\n' "$pid" "$user"
        return
    fi
    [ "$user" != "$(id -un)" ] || CAN_SUDO=0

    if ! signal_pid 15 "$pid"; then
        if alive "$pid"; then
            printf 'failed|%s|could not signal it\n' "$pid"
        else
            printf 'killed|%s|\n' "$pid"
        fi
        return
    fi

    while [ "$i" -lt 15 ]; do
        alive "$pid" || break
        sleep 0.2
        i=$((i + 1))
    done

    if alive "$pid"; then
        signal_pid 9 "$pid"
        sleep 0.3
    fi

    if alive "$pid"; then
        printf 'failed|%s|still running\n' "$pid"
    else
        printf 'killed|%s|\n' "$pid"
    fi
}

# The process table can lag a moment behind; the assertion list is what
# actually decides whether the Mac may sleep, so verify against that.
assertions_left() {
    local n
    n="$(pmset_source | grep -c '(caffeinate)' 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

report_stop() {
    local state pid detail

    while IFS='|' read -r state pid detail; do
        [ -n "$pid" ] || continue
        case "$state" in
            killed) printf '  %sStopped %s%s\n' "$c_ok" "$pid" "$c_reset" ;;
            skipped) printf '  %sSkipped %s - %s%s\n' "$c_warn" "$pid" "$detail" "$c_reset" ;;
            *) printf '  %sFailed %s - %s%s\n' "$c_err" "$pid" "$detail" "$c_reset" ;;
        esac
    done
}

stop_rows() {
    local pid user
    local results=""

    while IFS='|' read -r _ pid _ user _ _ _ _ _ _ _; do
        [ -n "$pid" ] || continue
        results="${results}$(stop_pid "$pid" "$user")
"
    done

    printf '%s' "$results" | report_stop
}

# ------------------------------------------------------------------ confirming

confirm() {
    local prompt="$1"
    local answer=""

    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi

    printf '%s [y/N] ' "$prompt"

    if ! read -r answer; then
        if ! { read -r answer < /dev/tty; } 2>/dev/null; then
            echo ""
            printf '%sError: No input available for confirmation. Use -y to skip it.%s\n' \
                "$c_err" "$c_reset" >&2
            exit 1
        fi
    fi

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------- non-interactive run

if [ "$INTERACTIVE" -eq 0 ]; then
    trap 'rm -f "$ROWS"' EXIT
    reload_rows

    case "$MODE" in
        list)
            echo ""
            print_table
            echo ""
            [ "$(row_count)" -gt 0 ] || exit 0
            ;;
        kill-one)
            if ! grep -q "^[0-9]*|${KILL_PID}|" "$ROWS"; then
                printf '%sError: %s is not a caffeinate process listed here.%s\n' \
                    "$c_err" "$KILL_PID" "$c_reset" >&2
                exit 1
            fi
            echo ""
            print_table
            echo ""
            confirm "Stop caffeinate $KILL_PID?" || { echo "Cancelled."; exit 0; }
            grep "^[0-9]*|${KILL_PID}|" "$ROWS" | stop_rows
            ;;
        kill-all)
            if [ "$(row_count)" -eq 0 ]; then
                echo ""
                print_table
                echo ""
                exit 0
            fi
            echo ""
            print_table
            echo ""
            confirm "Stop all $(row_count) caffeinate process(es)?" ||
                { echo "Cancelled."; exit 0; }
            stop_rows < "$ROWS"
            ;;
    esac

    if [ "$MODE" != "list" ]; then
        echo ""
        if [ "$(assertions_left)" -eq 0 ]; then
            printf '  %sNo caffeinate assertion is left. This Mac can sleep normally.%s\n' \
                "$c_ok" "$c_reset"
        else
            printf '  %sSome caffeinate assertions are still held - run the command again.%s\n' \
                "$c_warn" "$c_reset"
        fi
        echo ""
    fi
    exit 0
fi

# ------------------------------------------------------------------ full screen

SUMMARY=""
STOPPED_ANY=0

leave_screen() {
    printf '\033[?25h\033[?1049l'
}

trap 'leave_screen; rm -f "$ROWS"' EXIT
trap 'exit 130' INT TERM

# Alternate screen, the way nano uses it: the list never scrolls the scrollback
# away, and whatever was stopped is reported on the real screen afterwards.
printf '\033[?1049h\033[?25l'

draw() {
    local n="$1"
    local sep

    printf '\033[H\033[2J'
    echo ""
    print_table
    echo ""

    sep="$(printf '%*s' "$COLS" '')"
    printf '%s%s%s\n' "$c_dim" "${sep// /-}" "$c_reset"

    if [ "$n" -eq 0 ]; then
        printf '  %s[R]%s refresh   %s[Q]%s quit\n' "$c_bold" "$c_reset" "$c_bold" "$c_reset"
        return
    fi

    if [ "$n" -le 9 ]; then
        printf '  %s[1-%s]%s stop one   ' "$c_bold" "$n" "$c_reset"
    else
        printf '  %s[1-9]%s stop one   %s[N]%s stop by number   ' \
            "$c_bold" "$c_reset" "$c_bold" "$c_reset"
    fi
    printf '%s[K]%s stop all   %s[R]%s refresh   %s[Q]%s quit\n' \
        "$c_bold" "$c_reset" "$c_bold" "$c_reset" "$c_bold" "$c_reset"
}

# Asks on the footer line, nano style, instead of scrolling the list away.
# The prompt goes to the terminal rather than stdout: callers capture stdout to
# read the answer, and a prompt written there would be captured with it.
ask_footer() {
    local prompt="$1"
    local answer=""

    printf '\033[?25h  %s ' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
    printf '\033[?25l' > /dev/tty
    printf '%s' "$answer"
}

footer_yes() {
    case "$(ask_footer "$1 [y/N]")" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

run_stop() {
    local rows="$1"
    local out

    printf '\033[?25h'
    out="$(printf '%s\n' "$rows" | stop_rows)"
    printf '\033[?25l'
    SUMMARY="${SUMMARY}${out}
"
    STOPPED_ANY=1
}

while :; do
    reload_rows
    COUNT="$(row_count)"
    draw "$COUNT"

    KEY=""
    IFS= read -rsn1 KEY < /dev/tty || break

    case "$KEY" in
        q|Q) break ;;
        r|R) continue ;;
        k|K)
            [ "$COUNT" -gt 0 ] || continue
            if footer_yes "Stop all $COUNT caffeinate process(es)?"; then
                run_stop "$(cat "$ROWS")"
            fi
            ;;
        n|N)
            [ "$COUNT" -gt 0 ] || continue
            PICK="$(ask_footer "Stop which # (1-$COUNT)?")"
            case "$PICK" in
                ''|*[!0-9]*) continue ;;
            esac
            if [ "$PICK" -lt 1 ] || [ "$PICK" -gt "$COUNT" ]; then
                continue
            fi
            TARGET="$(row_at "$PICK")"
            TPID="$(printf '%s' "$TARGET" | cut -d'|' -f2)"
            if footer_yes "Stop caffeinate $TPID?"; then
                run_stop "$TARGET"
            fi
            ;;
        [1-9])
            [ "$KEY" -le "$COUNT" ] || continue
            TARGET="$(row_at "$KEY")"
            TPID="$(printf '%s' "$TARGET" | cut -d'|' -f2)"
            if footer_yes "Stop caffeinate $TPID?"; then
                run_stop "$TARGET"
            fi
            ;;
    esac
done

leave_screen
trap 'rm -f "$ROWS"' EXIT

if [ "$STOPPED_ANY" -eq 1 ]; then
    echo ""
    printf '%s' "$SUMMARY" | sed '/^$/d'
    echo ""
    if [ "$(assertions_left)" -eq 0 ]; then
        printf '  %sNo caffeinate assertion is left. This Mac can sleep normally.%s\n' \
            "$c_ok" "$c_reset"
    else
        printf '  %sSome caffeinate assertions are still held.%s\n' "$c_warn" "$c_reset"
    fi
    echo ""
fi
