# `lazy claude.guard [options]`

Stops Claude Code starting in a repository that is not yours to run it in.

Claude Code can be configured to report the current Git repository name to a
monitoring backend. On a machine set up that way, opening Claude Code in a
personal side project leaks that project's name to the employer's telemetry.
"Just check which directory you are in" only has to fail once, and it cannot be
taken back afterwards.

This command installs two layers in front of the real executable:

| Layer | What it does |
|---|---|
| Repository allowlist | `claude` only starts when the `origin` remote of the current repository matches. A non-Git directory, a repository with no `origin`, and anybody else's repository are all refused. |
| Kill switch (on by default) | `claude` refuses everywhere, and the execute bit is removed from the executable so an absolute path cannot get round it either. `claude-run` opens it for exactly one session. Install with `--no-arm` to leave this off. |

It never touches telemetry, `OTEL_*`, or managed settings. The point is to keep
Claude Code out of the wrong repository, not out of monitoring.

```bash
lazy claude.guard                 # derive the allowlist from this repo, install, ask first
lazy claude.guard --check         # report what is installed and what would change
lazy claude.guard -y              # install without the confirmation
lazy claude.guard --no-arm        # allowlist only; leave the kill switch disarmed
lazy claude.guard --exact         # allow only this repository, not its whole organisation
lazy claude.guard --allow 'github.com/other-org/*'   # extra entries (repeatable)
lazy claude.guard --bin ~/.local/bin/claude          # point at the executable yourself
lazy claude.guard --rc ~/.zprofile                   # wire a different startup file
lazy claude.guard --uninstall     # remove it all and restore the executable
```

## Where the allowlist comes from

Run it inside the company repository. The `origin` remote is read and reduced to
`host/org/repo`:

```
git@github.com-work:acme-ltd/billing.git   ->   github.com-work/acme-ltd/billing
```

By default the organisation is allowed, not just that one repository, so sibling
repositories work without re-running anything:

```
github.com-work/acme-ltd/*
github.com/acme-ltd/*
```

The second line appears because `github.com-work` is a per-account alias in
`~/.ssh/config` whose `HostName` is `github.com`. Both spellings name the same
organisation, so both are allowed; the same repository cloned on a machine
without the alias still matches.

A whole Git host is never allowed. `*` only ever stands for one path segment,
because a remote that does not reduce to exactly host + organisation + repository
is rejected outright. That is what keeps these out:

| Remote | Why it is refused |
|---|---|
| `git@github.com:someone/side.git` | different organisation |
| `git@github.com:acme-ltd-evil/r.git` | lookalike organisation |
| `https://github.com.evil.com/acme-ltd/r.git` | lookalike host |
| `git@github.com:acme-ltd/../other/r.git` | path traversal |
| `/srv/local/repo` | not a remote |

## Daily use

The kill switch is armed by default, so after installing, `claude` refuses
everywhere and `claude-run` is how you start a session. That is the point: if
`claude` still worked inside the allowed repository, the habit this is meant to
break would survive.

With `--no-arm` only the allowlist applies, and `claude` starts normally inside
an allowlisted repository.

| Command | What it does |
|---|---|
| `claude` | refuses, and says what to run instead |
| `claude-run` | one session; re-arms the kill switch when Claude Code exits |
| `claude-reblock` | arm it |
| `claude-reblock -q` | re-assert it quietly; no output, skips a live session |
| `claude-unblock` | disarm it entirely until you re-arm it |

`claude-run` exists because disarming globally means the protection is gone
until somebody remembers to put it back, which in practice means it is gone
after its first use.

## Example

```
Platform:    WSL
Executable:  /home/you/.local/bin/claude
             -> /home/you/.local/share/claude/versions/2.1.289
Locks:       every release in /home/you/.local/share/claude/versions
Guard dir:   /home/you/.local/bin-guard
Startup:     /home/you/.bashrc
Allowlist:
  github.com-work/acme-ltd/*
  github.com/acme-ltd/*
             from origin: git@github.com-work:acme-ltd/billing.git
             note: 'github.com-work' is an SSH alias for 'github.com' in ~/.ssh/config; both are allowed
Kill switch: off
Executable now: 1 file(s) carry the execute bit

Will:
  write the guard scripts into /home/you/.local/bin-guard
  add a guard block to /home/you/.bashrc (PATH + self-heal)
  arm the kill switch: 'claude' will refuse in EVERY directory
    (use 'claude-run' for one session, or re-run with --no-arm)

Apply? [y/N]
```

Refused because the kill switch is armed, in the allowed repository:

```
  CLAUDE CODE DISABLED

  The kill switch is armed; no repository can start Claude Code.
  Armed at: 2026-10-05 13:52:11 +0700

  One deliberate session (kill switch stays armed):  claude-run
  Disarm it entirely:                                claude-unblock
```

Refused by the allowlist (with the kill switch disarmed), in a repository that
is not on the list:

```
  CLAUDE CODE BLOCKED   Repository is not on the allowlist. origin: git@github.com:someone/side.git

  cwd: /home/you/code/side
  allowlist:
  github.com-work/acme-ltd/*
  github.com/acme-ltd/*
```

## What it writes

| Path | What it is |
|---|---|
| `~/.local/bin-guard/claude` | the guard; first on `PATH`, so it answers to `claude` |
| `~/.local/bin-guard/claude-run` | one guarded session with the kill switch still armed |
| `~/.local/bin-guard/claude-reblock` | arm, or re-assert with `-q` |
| `~/.local/bin-guard/claude-unblock` | disarm |
| `~/.local/bin-guard/claude-guard-common.sh` | the allowlist and shared logic |
| `~/.local/bin-guard/claude.exe` | WSL only; shadows a Windows-side install |
| `~/.claude/claude-code-disabled` | present while the kill switch is armed |
| `~/.claude/claude-run-leases/<pid>` | marks a live `claude-run` session |
| `~/.bashrc` (or `~/.zshrc`) | one block between `>>> lazy claude.guard >>>` markers |

The startup block does three things: it puts the guard directory first on
`PATH`, drops any stale `claude` shell function, and calls `claude-reblock -q`.

`PATH`, not an alias or a shell function, so `command claude`, `\claude` and
non-interactive child shells go through the guard too.

Nothing is installed with `sudo` and nothing outside your home directory is
touched. Re-running the command is safe: the startup block is replaced rather
than appended, and scripts left behind by an older hand-rolled version of this
guard in `~/.local/bin` are cleaned up.

## Why the startup file re-asserts the kill switch

Claude Code is a TUI, so it has to run in the foreground, and Bash defers traps
while a foreground child is running. A `claude-run` session killed with
`SIGKILL` therefore never reaches its cleanup, and would leave the executable
unlocked with the kill switch silently off — the worst kind of failure, because
everything still looks protected.

`claude-reblock -q` in the startup file closes that: every new shell re-asserts
the lock if the flag says it should be locked. It skips the check while a
`claude-run` session is genuinely live, which is what the lease files under
`~/.claude/claude-run-leases/` are for; leases whose process is gone are pruned
as they are found.

## Platform differences

| Platform | Notes |
|---|---|
| Linux | Full support. |
| WSL | Full support, plus the `claude.exe` shadow. A Windows-side install run from PowerShell or cmd is outside this guard: `/mnt/c` is a `drvfs`/`9p` mount with no real execute bit, so nothing on the Linux side can lock it. Remove it on Windows with `winget uninstall Anthropic.ClaudeCode` if that matters. |
| macOS | Full support. `~/.zshrc` is wired for zsh; for bash, `~/.bash_profile` is used when it exists and does not already source `~/.bashrc`, because a Terminal tab is a login shell. |
| Git Bash | Excluded. The kill switch depends on a real Unix execute bit; on NTFS `chmod` is emulated and does nothing. |

The executable is found on `PATH`, skipping the guard directory itself. When the
native installer is in use — one binary per release under
`~/.local/share/claude/versions/` with a launcher symlink — the whole directory
is locked, because locking only today's binary would be undone by the next
auto-update. A Homebrew or npm install has no such directory, so the resolved
binary is locked on its own.

## Undo

```bash
lazy claude.guard --uninstall
```

That restores the execute bit, clears the kill switch flag, removes everything
under `~/.local/bin-guard`, drops the lease directory, and takes the block back
out of the startup file. Open a new terminal afterwards.

By hand, if the CLI is not available:

```bash
rm -f  ~/.claude/claude-code-disabled
chmod u+x ~/.local/share/claude/versions/*     # or the single binary
rm -rf ~/.local/bin-guard ~/.claude/claude-run-leases
# then delete the block between the two markers in ~/.bashrc
```
