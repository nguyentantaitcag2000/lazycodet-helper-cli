# lazycodet-helper-cli

Small Bash CLI helpers for Git workflows.

## Commands

- `lazy branch.history` — interactive checkout history from the reflog (requires `fzf`)
- `lazy kill <port>` — list the processes listening on a port and kill them after confirmation
- `lazy update` — update the installed CLI

### `lazy kill`

```bash
lazy kill 3000        # list processes on port 3000, then ask before killing
lazy kill 3000 -y     # skip the confirmation prompt
```

Example:

```
Processes on port 3000:

  PID      NAME
  17020    node

Kill 1 process(es) on port 3000? [y/N] y
Killed 17020

Port 3000 is free.
```

On Linux it uses `lsof`, falling back to `ss`, `fuser`, or `netstat`, and sends `SIGTERM` before `SIGKILL`. On Git Bash it uses `netstat`/`tasklist`/`taskkill /T` (kills the whole process tree) and only targets `LISTENING` sockets — including IPv6 addresses like `[::1]:3000`, which is what Nuxt uses when `host` is `localhost` on Windows.

## Install

Copy and paste into the terminal (Linux, WSL, or Git Bash):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/install.sh)
```

If process substitution is unavailable, use:

```bash
curl -fsSL https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/install.sh | bash
```

The installer detects the environment automatically:

| Environment | What it does |
|---|---|
| **Linux / WSL** | Installs to `/opt/lazy`, symlinks `lazy` → `/usr/local/bin` (uses `sudo`) |
| **Git Bash** | Installs to `~/.lazy`, wrapper at `~/bin/lazy`, adds `~/bin` to `PATH` in `~/.bashrc` (no `sudo`) |

### After install

**Linux / WSL** — run immediately:

```bash
lazy branch.history
```

**Git Bash** — reload the shell first:

```bash
source ~/.bashrc
lazy branch.history
```

### Dependency: fzf

`branch.history` needs [fzf](https://github.com/junegunn/fzf).

- Linux / WSL: install via your package manager, e.g. `sudo apt install fzf`
- Git Bash (Windows): `scoop install fzf` or [download a release](https://github.com/junegunn/fzf/releases)
