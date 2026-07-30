# lazycodet-helper-cli

Small Bash CLI helpers for Git workflows.

## Commands

- `lazy branch.history` — interactive checkout history from the reflog (requires `fzf`)
- `lazy git.remember` — store the Git username/password for the current repo so it stops asking
- `lazy kill <port>` — list the processes listening on a port and kill them after confirmation
- `lazy update` — update the installed CLI

### `lazy git.remember`

```bash
lazy git.remember              # authenticate against origin
lazy git.remember upstream     # another remote
lazy git.remember -f           # replace the credential already stored
```

It checks whether the repository can already authenticate with the remote. If it
can, it says so and stops. If it cannot, it asks for the username and
password/token, verifies them against the remote (re-prompting when they are
wrong, up to 3 attempts), and only then saves them with:

```bash
git config --local credential.helper "store --file=.git/.git-credentials"
```

Example:

```
Remote:  origin -> https://github.com/acme/web.git
No credential stored for github.com yet.

Note: use a personal access token as the password — github.com rejects account passwords.

Attempt 1/3
Username: acme-bot
Password / token (hidden):
Verifying against github.com ... failed

Authentication failed — wrong username or password/token.

Attempt 2/3
Username [acme-bot]:
Password / token (hidden):
Verifying against github.com ... ok

Saved. Git will no longer ask for this repository.
```

Nothing is written unless the credential actually works. The store file lives
inside `.git/`, so it is never committed; remove it with
`git config --local --unset credential.helper && rm -f .git/.git-credentials`.
SSH remotes are reported as "nothing to store" since they use keys.

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
