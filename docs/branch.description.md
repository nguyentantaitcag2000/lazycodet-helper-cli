# `lazy branch.description`

Shows a branch's description, then opens a menu to change it.

```bash
lazy branch.description                    # current branch, with the menu
lazy branch.description feature/login      # another branch
lazy branch.description --set "Login page" # no menu
```

## Example

```
Branch       main (current)
Description  Main integration branch

╭──────────────────────────────────────────────────────────╮
│ Action >                                                 │
│   ENTER = run   ESC = quit                               │
│ ▌ Edit description   open it in your Git editor          │
│ ▌ Quick edit         type a one-line description here    │
│ ▌ Clear description                                      │
│ ▌ Choose another branch                                  │
│ ▌ Quit                                                   │
╰──────────────────────────────────────────────────────────╯
```

| Menu item             | What it does                                                                                              |
| --------------------- | --------------------------------------------------------------------------------------------------------- |
| Edit description      | Runs `git branch --edit-description`, which opens your Git editor. Saving an empty file removes it.       |
| Quick edit            | Asks for one line right in the terminal, prefilled with the current text on Bash 4+. Empty input = no change. |
| Clear description     | Removes the description after a `y/N` confirmation. Shown only when there is one.                        |
| Choose another branch | Opens a branch picker (with descriptions) and makes the chosen branch the target.                        |
| Quit / `ESC`          | Leaves without changing anything else.                                                                    |

After each action the block is printed again with the new description, and the
menu comes back until you quit.

Without a branch argument the current branch is used. On a detached HEAD the
branch picker opens first.

## Options

| Option             | Effect                                                     |
| ------------------ | ---------------------------------------------------------- |
| `-e`, `--edit`     | Edit in your Git editor, then print the result.            |
| `-s`, `--set TEXT` | Set the description to `TEXT` (surrounding spaces trimmed). |
| `-c`, `--clear`    | Remove the description, without asking.                    |
| `-p`, `--print`    | Print the description and exit.                            |

Only one option may be given. The options never need fzf.

## What it changes

Only `branch.<name>.description` in the repository's `.git/config` — the same
setting `git branch --edit-description` writes. To undo, set it again or run
`git config --unset branch.<name>.description`. The editor is Git's own choice
(`GIT_EDITOR`, `core.editor`, then `VISUAL`/`EDITOR`).

## Requirements

Must be run inside a Git repository with at least one commit. The menu needs
[fzf](https://github.com/junegunn/fzf); without it the description is printed
and the flags above still work.

See also [`lazy branch`](branch.md) to list every branch with its description.
