# `lazy caffeinate`

Lists the `caffeinate` processes keeping this Mac awake — when each started,
how much of its timeout is left, what it is holding awake, and who started it —
and stops the ones you pick. macOS only.

```bash
lazy caffeinate              # interactive list with a key menu at the bottom
lazy caffeinate --list       # print the list and exit
lazy caffeinate --kill 41651 # stop one of them
lazy caffeinate --kill-all   # stop all of them
lazy caffeinate --kill-all -y
```

## Example

```
  3 caffeinate processes are keeping this Mac awake.

  #  PID     STARTED          RUNNING   REMAINING      HOLDS  COMMAND
  1  41651   today 00:03:02   6h 17m    1h 42m         DIMSU  caffeinate -dimsu -t 21600
     \_ started by 41649: /bin/zsh -c source ~/.claude/shell-snapshots/snap...
  2  73350   today 18:52:06   4m 11s    4m 49s         .I...  caffeinate -i -t 300
     \_ orphaned - whatever started it has already exited
  3  73550   Sep 09 22:10     1d 20h    until it ends  .I...  caffeinate -i sleep 600
     \_ wrapping 'sleep' (pid 73548) - stopping caffeinate does not stop it

  HOLDS: the caffeinate flags actually in force -
  D display  I idle system  M disk  S system  U user-active  . not held

--------------------------------------------------------------------------
  [1-3] stop one   [K] stop all   [R] refresh   [Q] quit
```

The menu at the bottom works like nano's: a single keypress, no Enter. Number
keys stop that row, `K` stops everything, `R` re-reads the list, `Q` leaves.
Each stop is confirmed on the footer line first. With more than nine rows,
`N` asks for a row number instead. The list is drawn on the alternate screen,
so quitting restores the terminal and prints only what was actually stopped.

Without a terminal — piped, redirected, or run from a script — it behaves like
`--list` instead of waiting for a keypress.

## The columns

| Column | Where it comes from |
|---|---|
| `STARTED` | `ps -o lstart`, shown as `today HH:MM:SS` or `Mon DD HH:MM` |
| `RUNNING` | `ps -o etime` |
| `REMAINING` | `pmset -g assertions`, the `Timeout will fire in N secs` line |
| `HOLDS` | which assertions `pmset` reports the process actually holding |
| `COMMAND` | `ps -o args`, truncated to the terminal width |

`REMAINING` is the number macOS itself is counting down, not `-t` minus the
elapsed time. When `pmset` does not report a timeout the command falls back to
that subtraction, so the column still works if a future macOS changes the
wording.

`HOLDS` is read back from the kernel rather than parsed out of the flags, so it
shows what is really in force. It is printed in the order of the caffeinate
flags themselves, which makes `caffeinate -dimsu` read as `DIMSU` and
`caffeinate -i` as `.I...`. Five dashes mean the process is running but holding
nothing.

Two values in `REMAINING` are not durations:

- **`no timeout`** — no `-t`, so it runs until something stops it. Shown in
  yellow, because this is the one that quietly keeps a Mac awake for days.
- **`until it ends`** — the `caffeinate <command>` form, which lives exactly as
  long as the command it wraps.

## The note under a row

- **`started by <pid>: <command>`** — the parent process. This is what tells you
  a leftover assertion came from, say, a Claude Code shell rather than something
  you started yourself.
- **`orphaned`** — the parent already exited, so nothing is going to clean this
  one up.
- **`wrapping '<name>' (pid N)`** — the `caffeinate <command>` form. Stopping
  the caffeinate releases the assertion but leaves the wrapped command running.
- **`owned by <user>`** — belongs to another user, so stopping it needs `sudo`.
  It is listed either way, and skipped rather than attempted without one.

## Stopping

`SIGTERM` first, so caffeinate releases its own assertions, then `SIGKILL`
after three seconds if it is still there. Afterwards the assertion list is read
again — a process that has exited is not proof on its own — and the result is
reported as either

```
  No caffeinate assertion is left. This Mac can sleep normally.
```

or a warning that something is still held.

Only pids that appear in the list can be stopped: `--kill` on anything else is
refused. Nothing is ever matched by command line. `pgrep -f caffeinate` and
`pkill -f caffeinate` both match the *shell* that launched a caffeinate,
because the word appears inside its `-c` string, and they can match the tool
searching for them; this command matches on the executable name instead.

## What it does not touch

Only `caffeinate` processes. Plenty of other things hold power assertions —
`powerd` while the display is on, `WindowServer` after a keypress, Docker,
media playback, an app like Amphetamine — and none of them are listed or
stopped here. When the list is empty but the Mac still will not sleep:

```bash
pmset -g assertions
```

## Undo

There is nothing to undo: stopping a `caffeinate` only releases a sleep
assertion, and the Mac returns to the sleep behaviour set in System Settings.
To keep it awake again, start a new one:

```bash
caffeinate -i             # no idle sleep, display may still turn off
caffeinate -i -t 3600     # for one hour
caffeinate -i <command>   # only while <command> runs
```

The last form is the one that cannot be left behind: it exits with the command
it wraps, which is exactly the situation the rest of this page is about.

## Platform

macOS only. `caffeinate` and `pmset` are macOS tools. Linux and WSL manage the
same idea through logind inhibitor locks (`systemd-inhibit`) and Windows
through `powercfg /requests`; both are different enough that reporting them
under this command would be misleading, so it is not offered there — see
[platform-support.md](platform-support.md).
