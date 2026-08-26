# Changelog

All notable changes to this project are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/).

## [2026-08-26]

### Added

- `lazy claude.auth [distro] [-u <user>] [-y] [--list] [--check]` — copies the Claude Code login from the Windows host into a WSL distro so `claude` in there is signed in without a second browser round-trip. It reports both sides first (host token and expiry, the distro's user, config dir, credential state and CLI path), then writes `~/.claude/.credentials.json` at mode `600` and merges only `oauthAccount` plus `hasCompletedOnboarding` into the distro's `~/.claude.json`, leaving its project history and settings alone. Without a distro argument it prints a numbered list and accepts a number or a name (case-insensitive). The payload travels as base64 on `wsl.exe` stdin so no token reaches the distro's process list, the result is verified by comparing `sha256sum` on both sides, both touched files are backed up to `<file>.lazy.bak`, and a distro that already holds the same login exits without writing. Git Bash only — from inside WSL or on plain Linux it says where to run it instead
- `docs/claude.auth.md` covering the flags, what is read and written on each side, how to undo it, and the shared-refresh-token caveat

## [2026-08-15]

### Added

- `lazy fix.font [--check] [--dry-run] [-y] [--no-registry]` — one-shot fix for garbled Vietnamese / accented text on Windows. It reports the state of eight encoding settings, then writes a UTF-8 locale and `chcp 65001` to `~/.bashrc`, `encoding`/`fileencodings` (including `cp1258`) to `~/.vimrc`, 8-bit meta handling to `~/.inputrc` (keeping `$include /etc/inputrc`), `Charset=UTF-8` to `~/.minttyrc`, `core.quotepath`/`i18n.*`/`gui.encoding` via `git config --global`, `CodePage=65001` plus a console font to `HKCU\Console` and its per-title subkeys, and UTF-8 console encoding to the PowerShell profile resolved from `$PROFILE`. Every write is marker-guarded so re-running is a no-op, existing files are backed up to `<file>.lazy.bak`, and Linux/WSL is left untouched
- `docs/` with one page per command (`branch.history`, `fix.font`, `git.remember`, `kill`, `update`) covering flags, example output, what each command writes and how to undo it

### Changed

- `README.md` is now a scannable overview only — a one-line description per command linking to its page in `docs/`, plus install instructions
- `CLAUDE.md` documents the rule: `README.md` stays short, technical detail lives in `docs/<command>.md`, and a new command needs both a README one-liner and its own doc file

### Fixed

- Removed `.install.sh.swp`, a vim swap file that had been committed by accident, and added a `.gitignore` so editor swap and backup files stay out of the repo

## [2026-07-31]

### Changed

- `lazy git.remember` no longer fails when there is nothing to attach the credential to. If the directory is not a Git repository yet, it says so and asks for the repository URL (re-prompting when the URL is not http(s) or has no host), verifies the username and password/token against it, then clones the repository into a subdirectory (default name from the URL, editable at the prompt) and stores the credential inside that clone. The clone reuses the verified credential, so it never asks again; when only the URL-embedded fallback works, the remote URL is rewritten afterwards so no password stays in `.git/config`. An existing non-empty target directory stops the run with the `cd <dir> && lazy git.remember` hint instead of clobbering it.
- `lazy git.remember`: a repository that exists but has no remote gets the entered URL added as the remote instead of erroring. Naming a remote that does not exist in a repository that has others still errors with the list of available remotes.
- `lazy git.remember`: when a credential for the host already works but the repository still has to be cloned/wired up, it is reused instead of asking for the username and password again.
- `lazy git.remember`: a repository whose `HEAD` is unborn (a `git init` that never fetched anything — the state the previous version left behind) no longer stops at "nothing to do". It offers to `git fetch` and check out the remote's default branch, falling back to `main`/`master`/the first remote branch when the remote advertises no `HEAD`. Declining, a branchless remote, or a missing terminal just prints the `git fetch` hint and exits 0.
- `lazy git.remember`: that checkout is only offered when the worktree holds nothing but `.git`, since it lands in the current worktree rather than a subdirectory. A worktree rooted at `$HOME` warns that the `.git` was probably created by accident and prints the `rm -rf` command; any other worktree with files in it prints the manual `git fetch` command. Neither touches the directory.

## [2026-07-30]

### Added

- `lazy git.remember [remote] [-f]` — checks whether the repo can already authenticate with the remote; if not, prompts for username and password/token, verifies them against the remote (retrying up to 3 times on a wrong password), and stores them via `git config --local credential.helper "store --file=.git/.git-credentials"`. Credentials are passed through a temporary `GIT_ASKPASS` helper (falling back to a URL-embedded check when the helper cannot be executed), all prompting is disabled during probes so nothing hangs, and only the repo-local store is written — never the system/global helpers.

### Changed

- `lazy` with no arguments now lists a description next to each command, column-aligned from the longest invocation so the descriptions stay flush as commands are added
- Command names in the usage list are printed in bold cyan and descriptions dimmed, with color applied only on a TTY and skipped when `NO_COLOR` is set
- Unknown commands print the usage list after the error instead of only the error

### Fixed

- `lazy update` printing `unexpected EOF while looking for matching '"'` / `syntax error: unexpected end of file` after a successful update. Bash parses scripts lazily by byte offset, so rewriting the launcher while it is still running made bash resume parsing the new file at a stale offset (landing inside the `COMMANDS` array). `lazy.sh` now `exec`s the command file instead of running it as a child, and `update.sh` re-execs itself from a temporary copy before touching the install dir, so no file being rewritten is still being read.

## [2026-07-26]

### Added

- `lazy kill <port>` — list processes listening on a port and kill them after confirmation (`-y` to skip the prompt)
- Argument forwarding in `lazy.sh` so commands receive CLI args (e.g. `lazy kill 3000`)

### Changed

- `lazy kill` (Git Bash / Windows): only targets `LISTENING` sockets, shows the listen address (including IPv6 like `[::1]:3000`), kills the full process tree (`taskkill /T`), and verifies the port is free before reporting success
- `lazy update`: syncs the install checkout with `fetch` + `reset --hard` + `clean -fd` so local edits in the install dir no longer block updates (Linux and Git Bash)
- Linux `lazy update`: updates the full `/opt/lazy` git install instead of curling only `lazy.sh`, so new command files are delivered

### Fixed

- Port still in use after kill when Nuxt/Vite held `[::1]:3000` (Windows `localhost` prefers IPv6) or left child `node` processes alive

## [2026-07-19]

### Added

- Git Bash / MSYS install path (`~/.lazy`, wrapper at `~/bin/lazy`, PATH via `~/.bashrc`)
- Shared platform helpers in `lib/platform.sh`
- Modular `commands/` layout with `lazy branch.history` and `lazy update`
- CI workflow for bash syntax / shellcheck

### Changed

- Installer detects Linux/WSL vs Git Bash and installs accordingly
- README documents both environments and the `fzf` dependency for `branch.history`
