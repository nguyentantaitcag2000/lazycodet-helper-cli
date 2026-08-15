# CLAUDE.md

This project should run on both Linux (including WSL) and Git Bash (Windows). Prefer changes that keep Linux behavior stable and add Git Bash support as a separate path when needed.

When adding a feature or making a significant change, update `CHANGELOG.md`.

## Documentation

Keep `README.md` short. A reader should be able to scan it and understand what
each command is for, then install the CLI — nothing more.

- `README.md` holds only: what the project is, a one-line description per command
  with a link to its doc, and how to install it.
- Everything technical goes in `docs/<command>.md` — flags, example output, which
  files or settings are touched, platform differences, how to undo it.
- One doc file per command, named after the command (`docs/fix.font.md`).
- When adding a command, add its one-liner to `README.md` and create its doc file.

Do not put implementation detail, config tables, or troubleshooting steps in
`README.md`. If an explanation is longer than one sentence, it belongs in `docs/`.
