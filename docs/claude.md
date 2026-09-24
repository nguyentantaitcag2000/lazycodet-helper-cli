# `lazy claude [name]`

Keeps several Claude Code logins on one machine and switches which of them
`claude` is signed in as. Run it with no arguments for a picker: up and down
move, ENTER switches, `[a]` signs in to another account, `[d]` forgets one,
`[e]` exports one, `[i]` imports one, and `[q]` or ESC quits.

```
  Claude accounts

    alpha    alpha@example.com  max   token valid until 2026-09-16 04:12
  > * beta   beta@example.com   team  token valid until 2026-09-15 23:53
    + add another account (browser sign-in)

  up/down move   ENTER switch   [a] add   [e] export   [i] import   [d] forget   [q] quit
```

`*` marks the account `claude` is signed in as right now.

```bash
lazy claude                  # the picker
lazy claude beta             # switch straight to a saved account
lazy claude --add            # sign in to another account, then switch to it
lazy claude --add --name work   # ... and name it yourself
lazy claude --list           # print the accounts, change nothing
lazy claude --current        # print the name of the account in use
lazy claude --remove beta    # forget a saved account
lazy claude --export beta    # write ./claude-auth-beta.json
lazy claude --export beta --output /path/to/beta.json
lazy claude --import /path/to/beta.json
lazy claude --import /path/to/beta.json --name beta-mac
lazy claude beta -y          # skip the confirmations
```

On the first run, it adopts any login already on the machine and names it after
the email local part. If there is no login, the picker still opens: press `[a]`
to sign in through the browser or `[i]` to import a transferred auth file.
Nothing about an adopted login is changed.

## Moving a login to another machine

Highlight an account in the picker and press `[e]`, or export it directly:

```bash
lazy claude --export work --output ./claude-auth-work.json
```

Move that file to the other machine, open `lazy claude`, press `[i]`, and enter
its path. For scripts, use `lazy claude --import <file>`. The portable file
contains only the selected account's credentials and identity; it does not
contain project history, MCP servers, settings, or other saved accounts.

Import previews the account and asks before changing the live login. It saves
the account under `~/.claude-accounts`, writes its credentials to the store
Claude Code uses on that machine, and merges only the account identity and
onboarding fields into `~/.claude.json`. Existing project history, MCP servers,
and settings remain unchanged; the previous live credentials and config retain
the usual `.lazy.bak` recovery copies.

The export is plain JSON containing a live refresh token. Treat it like a
password: close Claude Code on the source machine, transfer the file through a
trusted channel, and delete it after a successful import. Claude rotates refresh
tokens, so continuing to use the same account on the source machine can
invalidate the imported copy.

## Adding an account

`--add` runs `claude auth login` with `CLAUDE_CONFIG_DIR` pointed at a throwaway
directory, so the browser flow writes its tokens there instead of over the login
in use. On Linux, WSL and Git Bash the account you are currently signed in as is
untouched for the whole flow, including when the sign-in is abandoned half way.
When it completes, the new tokens are saved as their own account and switched
in.

Signing in again as an account that is already saved refreshes it in place
rather than leaving a second copy behind.

## Why switching does not break the other account

Claude Code hands out a **new refresh token every time it renews the access
token**, and the previous one stops working. So an account saved when you
switched away from it goes stale the moment that account is used again — and
restoring that stale copy later is exactly what logs an account out for good.

Every run therefore begins by writing the live tokens back into the account they
belong to, before anything else happens:

| Situation | What happens |
|---|---|
| live tokens belong to the account marked in use | the saved copy is refreshed from them |
| live tokens belong to another saved account | that account is refreshed, and marked as the one in use |
| live tokens belong to no saved account | it is saved as a new account |
| the credentials file has no token (a logout) | nothing is archived — a logout cannot wipe a saved account |
| `~/.claude.json` has no account record | nothing is archived, and a switch asks before replacing the login it could not save |

The account identity is `oauthAccount.accountUuid` from `~/.claude.json`. A
saved account is only ever overwritten by tokens whose identity matches it, so a
login made outside `lazy` cannot land on top of a different account's copy.

If a `claude` session looks like it is still running, the command warns before
switching: that session holds the old tokens in memory and writes them back on
its next renewal, which would land them on the account just switched in.

## What it reads and writes

| Path | What happens |
|---|---|
| `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`) | read on every run, replaced on a switch, mode `600`, previous copy left at `.lazy.bak` |
| `~/.claude.json` | `oauthAccount`, `userID` and `hasCompletedOnboarding` are replaced; previous copy left at `.lazy.bak` |
| `~/.claude/policy-limits.json` | moved aside on a switch so the new account's limits are fetched |
| `~/.claude-accounts/<name>/` | one directory per saved account: `credentials.json`, `account.json`, mode `700` |
| `~/.claude-accounts/active` | the name of the account currently signed in |
| `./claude-auth-<name>.json` | optional portable export, mode `600` where the filesystem supports it |

Everything else in `~/.claude.json` — project history, MCP servers, settings —
is left exactly as it was. The account-scoped caches in it (`modelAccessCache`,
`cachedUsageUtilization`, `orgModelDefaultCache` and the other `*Cache` keys)
are dropped on a switch so they are refetched for the new account rather than
showing the previous one's plan and limits.

The tokens are written first and read straight back through the same store. If
they did not land intact the credentials are restored and `~/.claude.json` is
never touched, so a failed switch leaves you signed in as you were.

`~/.claude-accounts` is read and written directly, so it can be moved with
`LAZY_CLAUDE_STORE`.

## Requirements

`node` or `python3`, to read and rewrite `~/.claude.json` without corrupting it.
The command stops with a clear message if neither is installed.

`--add` also needs the `claude` CLI on `PATH`.

## Undo

Both live files are backed up before a switch:

```bash
mv ~/.claude/.credentials.json.lazy.bak ~/.claude/.credentials.json
mv ~/.claude.json.lazy.bak ~/.claude.json
```

Each saved account also keeps the previous copy of its own tokens at
`~/.claude-accounts/<name>/credentials.json.bak`.

Forgetting an account only deletes the saved copy. If it is the account in use,
`claude` stays signed in as it — the command says so before it does anything.

## Platform

Runs on Linux, WSL, macOS and Git Bash.

On macOS, Claude Code keeps the tokens in the login keychain rather than in a
file on some builds. The command detects which store this machine actually uses
and reads and writes the keychain entry `Claude Code-credentials` when that is
the one in play — verifying the write by reading it back. Two consequences
there: adding an account replaces the single keychain entry, so the account in
use is archived first and then restored by the switch; and macOS may ask once
for permission to update the entry.

## Caveats

- One machine, one signed-in account. This changes which login `claude` uses; it
  does not let two accounts run side by side. For that, give each one its own
  `CLAUDE_CONFIG_DIR`.
- Close running `claude` sessions before switching. The command warns, but it
  cannot stop a session that is already running from writing its tokens back.
- An account that is left unused past its `refreshTokenExpiresAt` has to be
  signed in again; the list says `expired - sign in again` when that has
  happened.
