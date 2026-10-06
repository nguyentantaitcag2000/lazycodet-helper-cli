# `lazy agent.notify`

Install global spoken completion notifications for Claude Code and Codex. The
hook runs when the main agent finishes a turn and uses Windows' local
text-to-speech engine; it does not call an AI model, external API, or network
service.

```bash
lazy agent.notify
lazy agent.notify --check
lazy agent.notify --test
lazy agent.notify --uninstall
```

The default install is idempotent. Running it again updates the managed runtime
and keeps exactly one managed `Stop` hook for each agent. Existing settings and
unrelated hooks are preserved.

## What it installs

| Path | Purpose |
| --- | --- |
| `~/.local/share/lazy/agent-notify/agent-notify.mjs` | Shared hook runtime |
| `~/.claude/settings.json` | Claude Code user-level `Stop` hook |
| `~/.codex/hooks.json` | Codex user-level `Stop` hook |

If either JSON file does not exist, the installer creates it. `--uninstall`
removes a config file only when this command created it and nothing else remains
in it. Otherwise it removes only the managed hook.

Codex requires non-managed hooks to be reviewed. After installation, open
`/hooks` in Codex and trust the new global hook. Claude Code reads its user-level
hook on the next session.

## Spoken text

The runtime prefers `Microsoft Zira Desktop`, then `Microsoft Hazel Desktop`,
and otherwise uses the first Windows voice available. For an English final
response it reads the first short sentence after removing common Markdown. For
a non-English response it says the provider-specific fallback, such as:

> Codex has finished the task.

This keeps the announcement understandable with the English voices already
included in Windows and avoids installing another voice pack. Speech is played
directly and is not saved as an audio file.

Claude Code can emit a temporary `Stop` event while background work is still in
flight. The hook skips that event and waits for a later completed turn.

## Options

- `--check` verifies the runtime, both hook entries, and the Windows speech
  engine without changing anything.
- `--test` speaks “Lazy agent notifications are working” without changing hook
  configuration.
- `--uninstall` removes the two managed hooks and the copied runtime. It does
  not remove Codex's stored trust history or touch unrelated settings.

## Platform support

The command is available in WSL and Git Bash, where it can launch Windows
PowerShell and `System.Speech`. Native Linux and macOS support is not implemented.
The hook applies to locally executed Claude Code and Codex sessions; a cloud
session cannot invoke the Windows speech engine on this computer.
