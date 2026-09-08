# `lazy agent.sync`

Keeps the Codex agent configuration in a Git project linked to its Claude-owned
source files.

```bash
cd /path/to/project
lazy agent.sync
```

It can also target a repository, or any directory inside one, explicitly:

```bash
lazy agent.sync /path/to/project
```

## What it manages

| Source | Managed link |
|---|---|
| `CLAUDE.md` | `AGENTS.md` |
| `.claude/skills/<name>` | `.agents/skills/<name>` |

Only directories containing `SKILL.md` are treated as skills. A project does not
need to have `.claude/skills`; in that case only `AGENTS.md` is linked. Every link
uses a relative target, so it remains valid when the repository is moved or
cloned elsewhere.

The command also sets the repository-local Git option `core.symlinks=true`.

## Check mode

```bash
lazy agent.sync --check
lazy agent.sync /path/to/project --check
```

Check mode verifies `core.symlinks`, every expected link, its relative target,
and stale entries under `.agents/skills`. It does not change anything and exits
non-zero when the project needs synchronization.

## Safety

`lazy agent.sync` is safe to run repeatedly. It repairs missing or incorrect
managed links and removes stale skill links after their Claude source disappears.
It refuses to overwrite `AGENTS.md` or entries in `.agents/skills` when they hold
independent user content.

When Git checked out a symlink as a small text file, or a generated skill copy is
byte-for-byte unchanged, the command can convert it back to a real symlink. A
temporary backup is used during that conversion and removed only after the link
is created successfully.

## Requirements and platforms

- Git and Node.js must be available.
- Linux and WSL can normally create symlinks without extra setup.
- Git Bash uses native Windows symlinks. Enable Windows Developer Mode, or grant
  the account the **Create symbolic links** privilege, before running the command.

The project must contain `CLAUDE.md` and must already be a Git repository.

## Undo

Remove the managed links, then create independent files or directories if that
is what the project needs:

```bash
rm AGENTS.md
rm -rf .agents/skills
```

To remove the repository-local Git setting too:

```bash
git config --local --unset core.symlinks
```
