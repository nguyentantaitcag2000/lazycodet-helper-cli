# Changelog

All notable changes to this project are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/).

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
