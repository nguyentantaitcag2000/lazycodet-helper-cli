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
  ● feature/login      | 2026-08-15 09:12:03
  ○ main               | 2026-08-14 17:40:55
  ○ fix/session-expiry | 2026-08-13 11:02:18
```

`●` marks the branch you are on. Duplicates are removed, so each branch appears
once at its most recent checkout. `ENTER` runs `git checkout` on the selection;
`ESC` cancels without changing anything.

## How it works

The list is built from `git reflog`, filtered to `checkout: moving from` entries,
and then reconciled with the branches that exist right now:

- Renamed branches are listed under their current name. `git branch -m` leaves
  the old name in the reflog, so the `Branch: renamed` entries are replayed to
  carry each checkout forward to the name the branch has today. The branch keeps
  the date of the checkout it inherits.
- Branches that no longer exist locally are dropped, so a deleted branch cannot
  be picked only to fail with `pathspec ... did not match`. Detached-HEAD
  entries are dropped for the same reason.
- Branches that were never checked out under their current name are still
  listed, dated by their last commit instead of by a checkout. A branch created
  with `git branch <name>` and never visited appears this way.

## Requirements

Must be run inside a Git repository, and needs
[fzf](https://github.com/junegunn/fzf):

- Linux / WSL: `sudo apt install fzf`
- macOS: `brew install fzf`
- Git Bash (Windows): `scoop install fzf` or
  [download a release](https://github.com/junegunn/fzf/releases)
