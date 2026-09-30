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

The command fetches the newest backup and opens an `fzf` checkbox-style picker.
All available agent-file groups are checked initially. Use the arrow keys to move,
`Space` to check or uncheck the highlighted group, `Enter` to perform the
restore, or `Esc` to cancel without changing files.

Only checked groups are replaced. Credentials, histories, sessions, plugins,
general settings, Git config, and shell startup files are not restore targets.
Archives and manifest paths are validated and
fully extracted to a temporary directory before anything in the home directory
is changed. Immediately before replacement, current copies of checked paths are
archived under:

```text
~/.local/share/lazy/restore-backups/<timestamp>/
```

If replacement fails, the command attempts to roll all checked paths back to
that pre-restore state. The recovery directory is retained after success so the
restore can also be undone manually with `tar -xf <item>.tar -C "$HOME"`.

`fzf`, `git`, and `tar` are required. The command is supported on Linux, WSL,
macOS, and Git Bash.
