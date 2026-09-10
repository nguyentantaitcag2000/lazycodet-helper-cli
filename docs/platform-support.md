# Platform support

The CLI supports Linux, WSL, macOS, and Git Bash on Windows. Commands are not
required to exist on every platform when the operating-system feature they manage
has no equivalent there.

Status meanings:

- **Supported** — implemented and exposed by `lazy` on that platform.
- **Excluded** — intentionally not exposed because the required platform feature
  does not exist there.
- **Not implemented** — applicable in principle, but support has not been built.

| Command | Linux | WSL | macOS | Git Bash (Windows) |
|---|---|---|---|---|
| `agent.sync` | Supported | Supported | Supported | Supported¹ |
| `branch.history` | Supported | Supported | Supported | Supported |
| `claude.auth` | Excluded² | Excluded² | Excluded² | Supported |
| `fix.font` | Excluded³ | Excluded³ | Excluded³ | Supported |
| `git.remember` | Supported | Supported | Supported | Supported |
| `kill` | Supported (local) | Supported (local, WSL distros, Windows host) | Supported (local) | Supported (Windows host and WSL distros) |
| `update` | Supported | Supported | Supported | Supported |

1. Creating native Windows symlinks requires Developer Mode or the **Create
   symbolic links** privilege.
2. `claude.auth` drives `wsl.exe` from the Windows host. Linux and macOS do not
   provide that workflow; from inside WSL it must still be launched on the host.
3. `fix.font` changes Windows registry, console, PowerShell, and mintty settings.
   Those settings do not exist on Linux, WSL, or macOS.

The source of truth for runtime availability is the command registry in
`lazy.sh`. When this matrix and the registry disagree, update both in the same
change.
