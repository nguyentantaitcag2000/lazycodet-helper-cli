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
| `caffeinate` | Excluded² | Excluded² | Supported | Excluded² |
| `claude` | Supported | Supported | Supported⁵ | Supported |
| `claude.auth` | Excluded³ | Excluded³ | Excluded³ | Supported |
| `fix.font` | Excluded⁴ | Excluded⁴ | Excluded⁴ | Supported |
| `git.commit` | Supported | Supported | Supported | Supported |
| `git.remember` | Supported | Supported | Supported | Supported |
| `kill` | Supported (local) | Supported (local, WSL distros, Windows host) | Supported (local) | Supported (Windows host and WSL distros) |
| `laravel.fix-permission` | Supported | Supported⁶ | Not implemented⁷ | Excluded⁸ |
| `update` | Supported | Supported | Supported | Supported |

1. Creating native Windows symlinks requires Developer Mode or the **Create
   symbolic links** privilege.
2. `caffeinate` reports and stops macOS `caffeinate` processes through
   `pmset -g assertions`. Neither tool exists elsewhere. Linux and WSL express
   the same idea as logind inhibitor locks (`systemd-inhibit`) and Windows as
   `powercfg /requests`; those are different enough models that reporting them
   under this command would misdescribe them, so each would be its own command.
3. `claude.auth` drives `wsl.exe` from the Windows host. Linux and macOS do not
   provide that workflow; from inside WSL it must still be launched on the host.
4. `fix.font` changes Windows registry, console, PowerShell, and mintty settings.
   Those settings do not exist on Linux, WSL, or macOS.
5. `claude` reads and writes whichever credential store Claude Code actually
   uses on the machine: the `.credentials.json` file everywhere, and the login
   keychain entry `Claude Code-credentials` on the macOS builds that keep the
   tokens there. Every write is verified by reading it back through the same
   store.
6. Only for projects in the Linux filesystem. On a Windows drive (`/mnt/c`,
   `/mnt/d`, a `9p`/`drvfs` mount) chown and chmod have no real effect, so the
   command stops with an explanation instead of reporting a fix that did not
   happen.
7. The model applies to macOS, but the command relies on GNU `stat`/`find` and
   POSIX `setfacl`, while macOS has BSD tools and its own ACL syntax
   (`chmod +a`). It is not exposed there until that path is built and tested.
8. `laravel.fix-permission` sets Unix owners, groups, mode bits, and ACLs. NTFS,
   as seen from Git Bash, has none of those; `chmod` there is emulated and
   `chown` does nothing. Run it inside WSL or the container instead.

The source of truth for runtime availability is the command registry in
`lazy.sh`. When this matrix and the registry disagree, update both in the same
change.
