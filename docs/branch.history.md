# `lazy branch.history`

Shows the branches you recently checked out and switches to the one you pick.

```bash
lazy branch.history
```

## Example

```
Current branch: feature/login
ENTER = checkout branch
ESC   = cancel

  Branch History >
  ● feature/login       | 2026-08-15 09:12:03
  ○ main                | 2026-08-14 17:40:55
  ○ fix/session-expiry  | 2026-08-13 11:02:18
```

`●` marks the branch you are on. Duplicates are removed, so each branch appears
once at its most recent checkout. `ENTER` runs `git checkout` on the selection;
`ESC` cancels without changing anything.

## How it works

The list is built from `git reflog`, filtered to `checkout: moving from` entries.
It reflects where *you* have been in this clone, not every branch that exists —
branches you never checked out locally will not appear.

## Requirements

Must be run inside a Git repository, and needs
[fzf](https://github.com/junegunn/fzf):

- Linux / WSL: `sudo apt install fzf`
- Git Bash (Windows): `scoop install fzf` or
  [download a release](https://github.com/junegunn/fzf/releases)
