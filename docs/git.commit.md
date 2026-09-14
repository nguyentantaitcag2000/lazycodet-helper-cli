# `lazy git.commit`

Interactively select changed files and commit only those files.

```bash
lazy git.commit
```

The picker lists tracked modifications, staged changes, deletions, renames, and
untracked files. Use the arrow keys to move, `Space` to select or unselect a
row, `Enter` to continue, and `Esc` to cancel. After the picker closes, enter a
single-line commit message.

```text
 M  apps/admin-portal/composables/useAdminPersonalPost.ts
??  apps/admin-portal/tests/personal-post.test.ts
 M  apps/main-web/assets/js/api.ts
```

The two status columns have the same meaning as `git status --short`: the first
is the staging-area status and the second is the working-tree status.

## Staging behavior

The command commits the complete current content of every selected file. This
also supports new files and deletions. If a selected file has one version staged
and then was edited again, its latest working-tree version is committed.

Files that are already staged but are not selected are excluded from the commit
and remain staged afterwards. Their unstaged edits also remain unchanged. The
command does this with a temporary Git index and removes that index when it
finishes or is cancelled.

An in-progress merge, rebase, cherry-pick, revert, or unresolved conflict is
rejected. Complete or abort that Git operation first so a file-only commit
cannot accidentally replace its intended continuation commit.

## Requirements and platforms

`lazy git.commit` works on Linux, WSL, macOS, and Git Bash. It requires
[`fzf`](https://github.com/junegunn/fzf):

- Linux / WSL: `sudo apt install fzf`
- macOS: `brew install fzf`
- Git Bash: `scoop install fzf`

## What it changes

The command creates one normal Git commit on the current branch. Selected files
become clean when the commit succeeds. It does not change unselected files or
their staged state.

To undo the commit while keeping all index entries staged:

```bash
git reset --soft HEAD~1
```
