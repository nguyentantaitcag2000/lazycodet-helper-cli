# `lazy restore`

Restore allowlisted Claude Code and Codex agent files from the linked backup:

```bash
lazy restore
```

On a new machine, enter the repository address when prompted or provide it in
the command:

```bash
lazy restore --repository git@github.com:you/private-machine-backup.git
```

To change the linked address later, for example from HTTPS to SSH, pass
`--relink <url>`; see [Changing the linked repository](backup.md#changing-the-linked-repository).

The command fetches the newest backup, automatically detects whether it uses
the folder or archive format, and opens an `fzf` checkbox-style picker.
All standard agent-file groups are checked initially. Codex command rules are
shown but remain unchecked because an `allow` rule can let a command run outside
the sandbox without another prompt. Review that row and check it explicitly if
you want to restore those rules. Use the arrow keys to move, `Space` to check or
uncheck the highlighted group, `Enter` to perform the restore, or `Esc` to
cancel without changing files.

Only checked groups are replaced. Credentials, histories, sessions, plugins,
general settings, Git config, and shell startup files are not restore targets.
Stored items and manifest paths are validated and fully staged in a temporary
directory before anything in the home directory is changed. Immediately before
replacement, current copies of checked paths are archived under:

```text
~/.local/share/lazy/restore-backups/<timestamp>/
```

If replacement fails, the command attempts to roll all checked paths back to
that pre-restore state. The recovery directory is retained after success so the
restore can also be undone manually with `tar -xf <item>.tar -C "$HOME"`.

`fzf`, `git`, and `tar` are required. The command is supported on Linux, WSL,
macOS, and Git Bash.
