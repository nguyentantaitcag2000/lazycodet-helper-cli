# `lazy branch`

Lists local branches with their descriptions. Names and descriptions use
different colors, so they are easy to tell apart at a glance.

```bash
lazy branch
lazy branch --color=always | less -R
```

## Example

```
  chore/no-desc
  features/planting-management-list-v1  Planting management list
                                        Second line of notes
  fix/x.y                               Dotted branch name
● main                                  Main integration branch

Edit a description: lazy branch.description [branch]
```

- `●` marks the current branch. Its name is green; other names are cyan.
- Descriptions are yellow. A multi-line description continues under its first
  line; a branch without one shows only its name.
- Branches are listed in Git's order (by name).

## Options

| Option             | Effect                                                      |
| ------------------ | ----------------------------------------------------------- |
| `--color[=<when>]` | `auto` (default), `always`, or `never`. `--color` = always. |
| `--no-color`       | Same as `--color=never`.                                    |

`auto` colors only a terminal and honors `NO_COLOR`. When the output is piped,
the list is plain and the trailing hint is left out, so it can be used in
scripts.

## Where descriptions come from

A description is Git's own `branch.<name>.description` setting, the one written
by `git branch --edit-description`. Set or change it with
[`lazy branch.description`](branch.description.md). All descriptions are read
with one `git config --get-regexp` call, so the list stays fast with many
branches. Git moves the setting on `git branch -m` and removes it on
`git branch -d`.

This replaces a `git branches` alias built from `git branch --format` and one
`git config` call per branch.
