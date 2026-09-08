# `lazy claude.auth [distro]`

Syncs the Claude Code login between the Windows host and a WSL distro, so
whichever side you use next is signed in without opening a browser and pasting a
code again.

It picks the direction itself. The side whose `~/.claude/.credentials.json`
holds a live token is the source:

| Host | Distro | Direction |
|---|---|---|
| signed in | logged out / expired | host → distro |
| expired / logged out | signed in | distro → host |
| both signed in | | the one with the later `expiresAt` wins |
| same file on both sides | | nothing to do |
| neither signed in | | stops and tells you to log in on one side |

```bash
lazy claude.auth                # list the distros and ask which one
lazy claude.auth sandbox        # pick the direction, ask before overwriting
lazy claude.auth sandbox -y     # skip the confirmation
lazy claude.auth sandbox --check  # report both sides and the direction, write nothing
lazy claude.auth sandbox --pull   # force distro -> host
lazy claude.auth sandbox --push   # force host -> distro
lazy claude.auth --list         # just list the WSL distros
lazy claude.auth sandbox -u root  # target a user other than the distro default
```

Distro names are matched case-insensitively; without an argument you get a
numbered list and can answer with either the number or the name.

## Example

Host still valid, distro logged out:

```
Host (Windows):
  /c/Users/2427/.claude/.credentials.json
  signed in (access token valid until 2026-08-26 17:48)

Distro sandbox:
  user: tai   config: /home/tai/.claude
  credentials file present but no token (logged out)
  cli:  /home/tai/.local/bin/claude

Direction: host -> sandbox (the host holds the usable login)

Copy the host login into sandbox (/home/tai/.claude/.credentials.json)? [y/N] y

  credentials copied and verified (sha256 matches)
  account + onboarding flags merged into ~/.claude.json on the sandbox side
  previous credentials: /home/tai/.claude/.credentials.json.lazy.bak
  previous config:      /home/tai/.claude.json.lazy.bak

Done. Try it:
  wsl -d sandbox
  claude
```

Host token expired, distro still good — same command, other way round:

```
Direction: sandbox -> host (the host login is not usable and sandbox's is)

Copy sandbox's login onto this host (/c/Users/2427/.claude/.credentials.json)? [y/N] y

  credentials copied and verified (sha256 matches)
  account + onboarding flags merged into ~/.claude.json on the host side
  previous credentials: /c/Users/2427/.claude/.credentials.json.lazy.bak

Done. Try 'claude' here on Windows.
```

## How a side is judged

Only the files are read — `claude` itself is never launched, so nothing prompts
for a login in the middle of the check.

| State | What it means |
|---|---|
| `signed in` | `accessToken` has a value and `expiresAt` is in the future |
| `signed in but the access token expired …` | there is a token, but its clock ran out; the refresh token may still work |
| `credentials file present but no token` | what a logout leaves behind |
| `no credentials file` | never signed in there |

An expired token still beats no token: if only one side has one, that side is
the source and the command says the copy only helps if its refresh token is
still good.

## What it reads and writes

The source side is only read; the destination side is written:

| File | Read | Written |
|---|---|---|
| `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`) | the OAuth tokens | overwritten, mode `600` |
| `~/.claude.json` | only `oauthAccount`, plus `userID` / `lastOnboardingVersion` when the target has none | merged in place — `oauthAccount` and `hasCompletedOnboarding: true` |

The tokens alone still drop you on the login screen, which is why
`hasCompletedOnboarding` and the account block are merged too. Everything else
in the target's `~/.claude.json` — project history, MCP servers, settings — is
left as it was.

The payload travels as base64 on `wsl.exe` stdin, so no token appears in the
distro's process list, and the copy is verified by comparing `sha256sum` on both
sides before the command reports success.

Merging `~/.claude.json` needs `python3` or `node` on the receiving side. With
neither, the credentials are still copied and the command says so — `claude`
then asks the onboarding questions once, but not for a login.

## Undo

Both files are backed up before they are touched, on whichever side was written:

```bash
# after a host -> distro copy
wsl -d sandbox
mv ~/.claude/.credentials.json.lazy.bak ~/.claude/.credentials.json
mv ~/.claude.json.lazy.bak ~/.claude.json
```

```bash
# after a distro -> host copy, from Git Bash
mv ~/.claude/.credentials.json.lazy.bak ~/.claude/.credentials.json
mv ~/.claude.json.lazy.bak ~/.claude.json
```

Each run overwrites the previous `.lazy.bak`.

## Platform

Runs on Git Bash (Windows) only — it drives both sides from there. From inside
WSL, or on plain Linux, it stops and tells you to run it from Git Bash.

## Caveats

- Both installs then share one refresh token. Claude Code rotates tokens when it
  refreshes, so if one side later asks you to log in again, re-run this command:
  it now picks up whichever side is still valid rather than assuming the host.
- It copies a login, not an install. A distro without the `claude` binary gets
  the credentials and a warning; install the CLI there separately.
- macOS hosts keep credentials in the Keychain rather than in a file, so this
  Windows-to-WSL path does not apply there.
