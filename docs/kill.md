# `lazy kill <port>`

Lists the processes listening on a port and kills them after confirmation.

```bash
lazy kill 3000        # list processes on port 3000, then ask before killing
lazy kill 3000 -y     # skip the confirmation prompt
```

## Example

```
Processes listening on port 3000:

  PID      ADDRESS                NAME
  17020    [::1]:3000             node

Kill 1 process(es) on port 3000? [y/N] y
Killed 17020 (process tree)

Port 3000 is free.
```

If the port is still held after the kill, the remaining listeners are printed
instead of reporting success.

## Platform differences

| | How it finds and kills |
|---|---|
| **Linux / WSL** | `lsof`, falling back to `ss`, `fuser`, then `netstat`; sends `SIGTERM` to the process group before escalating to `SIGKILL` |
| **Git Bash** | `netstat` / `tasklist` / `taskkill /T`, which kills the whole process tree |

On Windows it only targets `LISTENING` sockets and matches IPv6 addresses such as
`[::1]:3000` — that is what Nuxt and Vite bind to when `host` is `localhost`,
and it is the usual reason a port looks free but still refuses to bind.
