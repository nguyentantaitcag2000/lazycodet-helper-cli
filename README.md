# lazycodet-helper-cli

Small Bash CLI helpers for Git workflows.

## Commands

- `lazy branch.history` — interactive checkout history from the reflog (requires `fzf`)
- `lazy update` — update the installed CLI

## Install

### Linux / WSL

```bash
bash install.sh
```

Installs to `/opt/lazy` and symlinks `lazy` into `/usr/local/bin` (uses `sudo`).

### Git Bash (Windows)

```bash
bash install.sh
```

The installer detects Git Bash / MSYS automatically and:

- clones into `~/.lazy`
- creates a wrapper at `~/bin/lazy` (no `sudo`)
- appends `~/bin` to `PATH` in `~/.bashrc` if needed

After install, restart Git Bash (or `source ~/.bashrc`), then:

```bash
lazy branch.history
lazy update
```

#### Dependency: fzf

`branch.history` needs [fzf](https://github.com/junegunn/fzf):

```bash
scoop install fzf
```

Or download a release binary and put it on your `PATH`.
