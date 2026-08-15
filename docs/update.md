# `lazy update`

Updates the installed CLI to the latest version from `origin`.

```bash
lazy update
```

Run this after new commands are added — it delivers new command files, not just
a new `lazy.sh`.

## What it does

| Environment | Install dir | Steps |
|---|---|---|
| **Linux / WSL** | `/opt/lazy` | `fetch` + `reset --hard` + `clean -fd`, re-`chmod`, re-symlink `/usr/local/bin/lazy` (uses `sudo`) |
| **Git Bash** | `~/.lazy` | same sync, then rewrites the `~/bin/lazy` wrapper |

The install directory is synced to the matching `origin` branch (`origin/main`
when `HEAD` is detached).

## Note

The install directory is **not** a working copy. Local edits there are discarded
on every update — that is deliberate, so a stray change cannot block an update.
Edit the project in your own clone instead.

If the install directory is missing, the command tells you to re-run
`install.sh` rather than trying to recreate it.

## Why it re-execs itself

An update rewrites the very scripts that are running it. Bash parses a script
lazily by byte offset, so continuing to read a file that `git reset --hard` just
replaced makes it resume at a stale position and report a bogus
`unexpected EOF` / `syntax error` *after* the update actually succeeded.

Two things prevent that: `lazy.sh` `exec`s the command file instead of running it
as a child, and `update.sh` copies itself to a temporary file and re-execs from
there before touching the install directory. Nothing being rewritten is still
being read.
