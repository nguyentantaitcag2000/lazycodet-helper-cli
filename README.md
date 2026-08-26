# lazycodet-helper-cli

Small Bash CLI helpers for everyday Git and terminal chores. Works on Linux, WSL
and Git Bash (Windows).

## Commands

| Command | What it does |
|---|---|
| [`lazy branch.history`](docs/branch.history.md) | Pick a recently checked-out branch and switch to it |
| [`lazy claude.auth`](docs/claude.auth.md) | Copy this machine's Claude Code login into a WSL distro |
| [`lazy fix.font`](docs/fix.font.md) | Fix garbled Vietnamese / accented text on Windows |
| [`lazy git.remember`](docs/git.remember.md) | Store this repo's Git login so it stops asking |
| [`lazy kill <port>`](docs/kill.md) | Kill whatever is listening on a port, in this machine or in another WSL distro |
| [`lazy update`](docs/update.md) | Update the installed CLI |

Run `lazy` to list them, or `lazy <command> --help` for the options.

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

| Environment | Where it installs |
|---|---|
| **Linux / WSL** | `/opt/lazy`, symlinked to `/usr/local/bin/lazy` (uses `sudo`) |
| **Git Bash** | `~/.lazy`, wrapper at `~/bin/lazy`, adds `~/bin` to `PATH` (no `sudo`) |

On Git Bash, reload the shell once after installing:

```bash
source ~/.bashrc
```

`lazy branch.history` also needs [fzf](https://github.com/junegunn/fzf)
(`sudo apt install fzf`, or `scoop install fzf` on Windows).
