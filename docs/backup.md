# `lazy backup`

Save the allowlisted Claude Code and Codex agent files, commit them, and push
them to a Git repository:

```bash
lazy backup
```

The default `folder` format stores ordinary files so changes can be reviewed
line by line on GitHub. To preserve full filesystem metadata and nested Git
metadata instead, select the original archive format:

```bash
lazy backup --format archive
```

Pass `--format folder` to switch an archive snapshot back to folders. The
selected format applies to that run; running `lazy backup` without the option
always uses `folder`. Switching replaces the previous snapshot in the next Git
commit rather than keeping two copies.

On the first run, enter the clone URL of an existing, dedicated repository. The
repository may be empty. The link and a local checkout are retained, so later
runs do not ask again. A non-interactive first run can provide the address
explicitly:

```bash
lazy backup --repository git@github.com:you/private-machine-backup.git
```

The command does not intentionally collect credentials or chat history. A
private repository is still recommended because instructions may contain
sensitive text and a skill may include executable scripts.

## What is backed up

Only entries that exist are included. Both formats use the same allowlist.

| Home path | Contents |
|---|---|
| `~/.claude/CLAUDE.md`, `~/.claude/CLAUDE.local.md` | Claude Code global instructions |
| `~/.claude/skills` | Claude Code skills |
| `~/.claude/agents` | Claude Code custom agents |
| `~/.claude/rules` | Claude Code rules |
| `~/.codex/AGENTS.md`, `~/.codex/AGENTS.override.md` | Codex global instructions |
| `~/.agents/skills` | Codex skills |
| `~/.codex/rules` | Codex command rules |

### Storage formats

| Format | Git repository layout | Tradeoff |
|---|---|---|
| `folder` (default) | Ordinary files below `items/files/` | GitHub can show line-by-line diffs. Symlinks and executable bits are retained, but empty directories, full POSIX permissions, and nested `.git` metadata are not. Groups containing no files after those omissions are skipped. |
| `archive` | One `items/<group>.tar` per detected group | Preserves permissions, symlinks, empty directories, and nested `.git` metadata, but GitHub treats changes as binary. |

The `items/format` marker records the representation. `lazy restore` reads it
automatically, so restore does not need a matching format option. Backups made
before this marker existed are treated as archive snapshots.

This is an explicit allowlist. In particular, it excludes `~/.ssh`, Claude and
Codex credentials, account stores, conversations, sessions, project history,
plugins, caches, general settings, Git configuration, and shell startup files.
The command does not search arbitrary project directories for project-local
`CLAUDE.md` or `AGENTS.md` files.

The command scans the home directory of the environment in which it runs. For
example, a run inside WSL backs up that distro's Linux home, while a run in Git
Bash backs up the Windows user's home. Credentials held only in an operating
system keychain are not exported.

Skills may legitimately contain scripts and other executable content. This
narrow allowlist greatly reduces the attack surface, but it is not an antivirus
scanner; review skills from an untrusted or compromised repository before using
them.

The checkout defaults to `~/.local/share/lazy/backup-repository`; the saved
repository address defaults to `~/.config/lazy/backup-repository`. XDG config
and data environment variables are respected. A backup first rebases on the
remote, replaces the previous snapshot, creates a commit only when content
changed, and pushes it.

## Changing the linked repository

`--repository` only links the first time; afterwards a different address is
rejected. To fix a mistyped address, switch transport, or move to another
repository, relink it:

```bash
lazy backup --relink git@github.com:you/private-machine-backup.git
```

The new address is checked with `git ls-remote` before anything changes, so an
unreachable address or a missing permission keeps the current link. After
relinking, the backup runs as usual. What happens to the local checkout depends
on the new remote:

| New remote | Local checkout |
|---|---|
| Same repository under another address (HTTPS to SSH) | Kept. Only `origin` changes, and a commit whose earlier push failed is pushed now. |
| Empty repository | Kept. The existing backup history is pushed to it. |
| Repository with unrelated history | Moved to `~/.local/share/lazy/backup-repository.previous.<timestamp>`, and the new repository is cloned. This is refused when the old checkout has commits that were never pushed. |

`lazy restore --relink <url>` does the same before restoring.

### Push denied with HTTPS (403)

An HTTPS address authenticates with whatever account the Git credential helper
or the terminal's `GIT_ASKPASS` supplies. The integrated terminal in VS Code,
for example, uses the GitHub account signed in to VS Code, which may not be the
owner of the backup repository:

```text
remote: Permission to you/private-machine-backup.git denied to other-account.
fatal: unable to access 'https://github.com/...': The requested URL returned error: 403
```

Relinking to the SSH address uses your SSH key instead. Check which account
that key belongs to with `ssh -T git@github.com`.

If an older version of `lazy backup` already pushed broader machine state,
narrowing the current snapshot does not erase those files from Git history.
Create a new repository or purge the old repository history before treating it
as free of credentials and conversations.

## Undo

Every snapshot is a normal Git commit. Check out or revert an earlier commit in
the backup repository, then run `lazy restore` to restore that version.
