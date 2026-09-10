# CLAUDE.md

This project supports Linux (including WSL), macOS, and Git Bash (Windows).
Prefer shared POSIX/Bash behavior where the operating systems agree, with an
explicit platform branch where their tools or semantics differ.

When adding a feature or making a significant change, update `CHANGELOG.md`.

## Platform Parity

Feature parity across platforms is **not** required. A command or option may be
available on one platform and intentionally absent on another when the underlying
operating-system capability does not exist there.

- Do not add a degraded, misleading, or no-op implementation only to make the
  command lists match. For example, a WSL-management command belongs on Windows
  even though WSL has no equivalent on macOS.
- Declare every command's supported platforms in the command registry in
  `lazy.sh`. The dispatcher and its usage output must omit commands that are not
  available on the current platform and reject direct invocation clearly.
- Apply the same rule to platform-specific flags: omit inapplicable flags from
  help on other platforms and reject them instead of silently doing nothing.
- Record each command in `docs/platform-support.md` with a distinct status for
  supported, not implemented yet, and intentionally excluded. An exclusion must
  include its platform reason.
- Shared commands must preserve behavior on Linux, WSL, macOS, and Git Bash.
  Platform-specific code must be guarded so it cannot affect the other paths.
- When a real platform limitation prevents a reliable implementation, prefer an
  intentional documented exclusion over a partially working port.

## Documentation

Keep `README.md` short. A reader should be able to scan it and understand what
each command is for, then install the CLI — nothing more.

- `README.md` holds only: what the project is, a one-line description per command
  with a link to its doc, and how to install it.
- Everything technical goes in `docs/<command>.md` — flags, example output, which
  files or settings are touched, platform differences, how to undo it.
- Project-wide platform availability is documented in `docs/platform-support.md`.
- One doc file per command, named after the command (`docs/fix.font.md`).
- When adding a command, add its one-liner to `README.md` and create its doc file.

Do not put implementation detail, config tables, or troubleshooting steps in
`README.md`. If an explanation is longer than one sentence, it belongs in `docs/`.
