# lazycodet-helper-cli

Small Bash CLI helpers for everyday Git and terminal chores. Works on Linux, WSL,
macOS, and Git Bash (Windows).

## Commands

| Command | What it does |
|---|---|
| [`lazy agent.sync`](docs/agent.sync.md) | Link Codex agent config to the Claude-owned source files in any Git project |
| [`lazy branch.history`](docs/branch.history.md) | Pick a recently checked-out branch and switch to it |
| [`lazy caffeinate`](docs/caffeinate.md) | List and stop the `caffeinate` processes keeping a Mac awake |
| [`lazy claude`](docs/claude.md) | Pick, add, switch, export, or import saved Claude Code accounts |
| [`lazy claude.auth`](docs/claude.auth.md) | Sync the Claude Code login between Windows and a WSL distro, in whichever direction is still valid |
| [`lazy fix.font`](docs/fix.font.md) | Fix garbled Vietnamese / accented text on Windows |
| [`lazy git.commit`](docs/git.commit.md) | Pick changed files and commit only those files without disturbing other staged changes |
| [`lazy git.remember`](docs/git.remember.md) | Store this repo's Git login so it stops asking |
| [`lazy kill <port>`](docs/kill.md) | Kill whatever is listening on a port, in this machine or in another WSL distro |
| [`lazy update`](docs/update.md) | Update the installed CLI |

Run `lazy` to list the commands available on your current platform, or
`lazy <command> --help` for their options.

## Install

Copy and paste into the terminal (Linux, WSL, macOS, or Git Bash):

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
| **macOS** | `/usr/local/lib/lazy`, symlinked to `/usr/local/bin/lazy` (uses `sudo`) |
| **Git Bash** | `~/.lazy`, wrapper at `~/bin/lazy`, adds `~/bin` to `PATH` (no `sudo`) |

On Git Bash, reload the shell once after installing:

```bash
source ~/.bashrc
```

`lazy branch.history` and `lazy git.commit` also need [fzf](https://github.com/junegunn/fzf)
(`sudo apt install fzf`, `brew install fzf` on macOS, or `scoop install fzf` on Windows).
