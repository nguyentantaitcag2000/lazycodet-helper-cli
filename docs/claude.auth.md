# `lazy claude.auth [distro]`

Copies the Claude Code login from the Windows host into a WSL distro, so `claude`
in that distro is signed in without opening a browser and pasting a code again.

```bash
lazy claude.auth                # list the distros and ask which one
lazy claude.auth sandbox        # copy into "sandbox", ask before overwriting
lazy claude.auth sandbox -y     # skip the confirmation
lazy claude.auth sandbox --check  # report both sides, write nothing
lazy claude.auth --list         # just list the WSL distros
lazy claude.auth sandbox -u root  # target a user other than the distro default
```

Distro names are matched case-insensitively; without an argument you get a
numbered list and can answer with either the number or the name.

## Example

```
Host (Windows):
  /c/Users/2427/.claude/.credentials.json
  signed in (access token valid until 2026-08-26 17:48)

Distro sandbox:
  user: tai   config: /home/tai/.claude
  credentials file present but no token (logged out)
  cli:  /home/tai/.local/bin/claude

Copy this login into sandbox (/home/tai/.claude/.credentials.json)? [y/N] y

  credentials copied and verified (sha256 matches)
  account + onboarding flags merged into ~/.claude.json
  previous credentials: /home/tai/.claude/.credentials.json.lazy.bak
  previous config:      /home/tai/.claude.json.lazy.bak

Done. Try it:
  wsl -d sandbox
  claude
```

A distro that already holds the same credentials exits with
`already holds this exact login - nothing to do` and touches nothing.

## What it reads and writes

| Side | File | Action |
|---|---|---|
| Windows | `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`) | read — the OAuth tokens |
| Windows | `~/.claude.json` | read — only `oauthAccount`, and `userID` / `lastOnboardingVersion` when the distro has none |
| WSL | `~/.claude/.credentials.json` | overwritten, mode `600` |
| WSL | `~/.claude.json` | merged in place — `oauthAccount` and `hasCompletedOnboarding: true` |

The tokens alone still drop you on the login screen, which is why
`hasCompletedOnboarding` and the account block are merged too. Everything else in
the distro's `~/.claude.json` — project history, MCP servers, settings — is left
as it was; the Windows-specific parts of the host file are never copied over.

The payload travels as base64 on `wsl.exe` stdin, so no token appears in the
distro's process list, and the copy is verified by comparing `sha256sum` on both
sides before the command reports success.

Merging `~/.claude.json` needs `python3` or `node` in the distro. With neither,
the credentials are still copied and the command says so — `claude` then asks the
onboarding questions once, but not for a login.

## Undo

Both files are backed up before they are touched:

```bash
wsl -d sandbox
mv ~/.claude/.credentials.json.lazy.bak ~/.claude/.credentials.json
mv ~/.claude.json.lazy.bak ~/.claude.json
```

Each run overwrites the previous `.lazy.bak`.

## Platform

Runs on Git Bash (Windows) only — that is where the host login lives. From
inside WSL, or on plain Linux, it stops and tells you to run it from Git Bash.

## Caveats

- Both installs then share one refresh token. Claude Code rotates tokens when it
  refreshes, so if one side later asks you to log in again, re-run this command
  to re-sync rather than authenticating twice.
- It copies a login, not an install. A distro without the `claude` binary gets
  the credentials and a warning; install the CLI there separately.
- macOS hosts keep credentials in the Keychain rather than in a file, so this
  Windows-to-WSL path does not apply there.
