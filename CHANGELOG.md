# Changelog

All notable changes to this project are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/).

## [2026-08-15]

### Added

- `lazy fix.font [--check] [--dry-run] [-y] [--no-registry]` — one-shot fix for garbled Vietnamese / accented text on Windows. It reports the state of eight encoding settings, then writes a UTF-8 locale and `chcp 65001` to `~/.bashrc`, `encoding`/`fileencodings` (including `cp1258`) to `~/.vimrc`, 8-bit meta handling to `~/.inputrc` (keeping `$include /etc/inputrc`), `Charset=UTF-8` to `~/.minttyrc`, `core.quotepath`/`i18n.*`/`gui.encoding` via `git config --global`, `CodePage=65001` plus a console font to `HKCU\Console` and its per-title subkeys, and UTF-8 console encoding to the PowerShell profile resolved from `$PROFILE`. Every write is marker-guarded so re-running is a no-op, existing files are backed up to `<file>.lazy.bak`, and Linux/WSL is left untouched
- `docs/` with one page per command (`branch.history`, `fix.font`, `git.remember`, `kill`, `update`) covering flags, example output, what each command writes and how to undo it

### Changed

- `README.md` is now a scannable overview only — a one-line description per command linking to its page in `docs/`, plus install instructions
- `CLAUDE.md` documents the rule: `README.md` stays short, technical detail lives in `docs/<command>.md`, and a new command needs both a README one-liner and its own doc file

### Fixed

- Removed `.install.sh.swp`, a vim swap file that had been committed by accident, and added a `.gitignore` so editor swap and backup files stay out of the repo

## [2026-07-30]

### Added

- `lazy git.remember [remote] [-f]` — checks whether the repo can already authenticate with the remote; if not, prompts for username and password/token, verifies them against the remote (retrying up to 3 times on a wrong password), and stores them via `git config --local credential.helper "store --file=.git/.git-credentials"`. Credentials are passed through a temporary `GIT_ASKPASS` helper (falling back to a URL-embedded check when the helper cannot be executed), all prompting is disabled during probes so nothing hangs, and only the repo-local store is written — never the system/global helpers.

### Changed

- `lazy` with no arguments now lists a description next to each command, column-aligned from the longest invocation so the descriptions stay flush as commands are added
- Command names in the usage list are printed in bold cyan and descriptions dimmed, with color applied only on a TTY and skipped when `NO_COLOR` is set
- Unknown commands print the usage list after the error instead of only the error

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
