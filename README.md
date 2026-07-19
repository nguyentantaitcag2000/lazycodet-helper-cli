# lazycodet-helper-cli

Small Bash CLI helpers for Git workflows.

## Commands

- `lazy branch.history` — interactive checkout history from the reflog (requires `fzf`)
- `lazy update` — update the installed CLI

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
