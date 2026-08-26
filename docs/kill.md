# `lazy kill <port>`

Lists what is listening on a port and kills it after confirmation.

```bash
lazy kill 3000          # list what holds port 3000, then ask before killing
lazy kill 3000 -y       # skip the confirmation prompts
lazy kill 80 --list     # only report, kill nothing
lazy kill 80 --local    # never look outside this machine
lazy kill 80 --all      # always search other WSL distros and the Windows host
```

## Example

```
What holds port 3000:

  WHERE                      PID      ADDRESS                WHAT
  this distro (sandbox)      17020    [::1]:3000             node  (node server.js)

Kill 1 target(s) on port 3000? [y/N] y
Killed 17020 (node) in this distro (sandbox) (process tree)

Port 3000 is free.
```

## The port is taken but there is nothing here to kill

WSL2 runs every distro inside one virtual machine, and they all share a single
network namespace — `ip addr` shows the same IP in each. Their PID namespaces
are separate, though. So when distro A publishes port 80:

- distro B genuinely cannot bind port 80,
- but `ss` and `lsof` inside distro B show the socket with an **empty process
  column**, because its owner lives in another PID namespace.

That is the case where the old version reported "no process is listening" and
left you to go hunting through distros by hand.

Now the search widens on its own. When the local scan finds no owner — or finds
a socket nobody here owns, or a Windows-side port forwarder — the command also
looks in every **running** WSL distro and on the Windows host, then asks before
touching anything out there:

```
What holds port 80:

  WHERE                      PID      ADDRESS                WHAT
  wsl: workway               771      0.0.0.0:80             container workway-nginx-1 (compose project workway)
  windows host               24096    127.0.0.1:80           wslrelay.exe  [skipped: WSL port forwarder, the real owner is inside a distro]

Kill 1 target(s), 1 of them in another WSL distro? [y/N] y
Stopped container workway-nginx-1 in workway

Port 80 is free.
```

Stopped distros are never started just to be searched — a distro that is not
running cannot be holding a port.

## Docker

When the listener is the forwarder in front of a published container port
(`docker-proxy`, or `rootlesskit`/`slirp4netns` on rootless Docker), the
container that publishes the port is stopped instead of the forwarder being
killed. Killing the forwarder would free the port but leave the container
running with its published port silently broken; `docker stop` is both cleaner
and undone with `docker start`.

A container using `network_mode: host` publishes nothing, so its listener is
treated as an ordinary process and killed.

## Two confirmations

Linux targets and Windows targets are asked about separately, because killing a
Windows service is a much bigger hammer than killing a dev server. `-y` skips
both.

## What is never killed

Some Windows processes only relay somebody else's port, or cannot be killed at
all. They are listed with a `[skipped]` note and left alone:

| Process | Why | What to do instead |
|---|---|---|
| `wslrelay.exe`, `wslhost.exe`, `wslservice.exe`, `vmmem` | One process forwards ports for *every* distro; killing it breaks port forwarding machine-wide | Let the WSL scan find the real owner inside the distro |
| `com.docker.backend.exe`, `vpnkit.exe`, `dockerd.exe` | Docker Desktop's own plumbing | Stop the container |
| `System`, `Idle`, `Registry` | The Windows kernel — `http.sys` is what holds 80/443 for IIS | `net stop http`, or `iisreset /stop` |
| `svchost.exe` | A shared service host | Stop the owning service |

## Options

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Skip every confirmation prompt |
| `--list` | Only report what holds the port, kill nothing |
| `--local` | Never look outside this machine |
| `--wsl` | Always search the other running WSL distros |
| `--host` | Always search the Windows host |
| `-a`, `--all` | Same as `--wsl --host` |

## Platform differences

| | How it finds and kills |
|---|---|
| **Linux** | `ss`, falling back to `lsof`, `netstat`, then `fuser`; `/proc/net/tcp` is the ground truth for whether the port is bound at all. Sends `SIGTERM` to the process group before escalating to `SIGKILL` |
| **WSL** | The same, plus other running distros over `wsl.exe -d <distro> -u root`, plus the Windows host over `netstat.exe` / `taskkill.exe` |
| **Git Bash** | `netstat` / `tasklist` / `taskkill /T` on the Windows host, and it drills into running WSL distros when the owner turns out to be in one |

On Windows only `LISTENING` sockets are targeted, and IPv6 addresses such as
`[::1]:3000` are matched — that is what Nuxt and Vite bind when `host` is
`localhost`, and the usual reason a port looks free but still refuses to bind.

Other distros are entered as `root`, because `docker-proxy` and most service
listeners are root-owned and their PID is invisible otherwise. In the current
distro, non-interactive `sudo` is used when it is available and never prompts
for a password.

## If it cannot reach the other distros

Reaching another distro needs Windows interop, and `systemd-binfmt` wipes the
`WSLInterop` registration on some images — which makes every `.exe` call fail
with `Exec format error`. The command re-registers it for the session and says
so. To keep it after a restart:

```bash
echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /usr/lib/binfmt.d/WSLInterop.conf
```

If it cannot be re-registered (no root and no passwordless `sudo`), the command
prints the one-line fix and keeps working locally.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | The port is free, or nothing was listening, or you declined |
| `1` | Something could not be killed, or the port is still held |
