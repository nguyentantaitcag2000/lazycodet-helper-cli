# `lazy fix.font`

Fixes garbled Vietnamese (and any accented) text on Windows.

```bash
lazy fix.font                # show what is wrong, ask, then fix it
lazy fix.font --check        # report only, change nothing (exit 1 if anything needs fixing)
lazy fix.font --dry-run      # print every planned change without applying it
lazy fix.font -y             # skip the confirmation prompt
lazy fix.font --no-registry  # skip the HKCU\Console and PowerShell profile fixes
```

## Why text comes out garbled

It is not a missing font — it is the shell locale. Git Bash starts with `LANG`
unset, which puts everything in the C locale:

- the Windows console falls back to code page 850 instead of 65001
- Vim opens UTF-8 files as `latin1`, so `Tiếng Việt` renders as separate garbage
  characters (Vim counts 30 characters where there are 19)
- TUI apps such as `claude` miscount the display width of accented characters and
  draw broken frames

## What it checks

```
UTF-8 setup (Git Bash / Windows):

  ITEM                    STATUS  DETAIL
  shell locale            FIX     LANG is empty (C locale)
  console code page       FIX     850 (want 65001)
  vim encoding            FIX     ~/.vimrc is missing
  readline input          FIX     ~/.inputrc is missing
  mintty charset          FIX     ~/.minttyrc is missing
  git encoding            FIX     4 setting(s) missing
  HKCU\Console code page  FIX     not set to 65001
  PowerShell profile      FIX     profile.ps1 is missing
```

`--check` exits 1 while anything still reads `FIX`, so it works in scripts.

## What it writes

| Target | Change |
|---|---|
| `~/.bashrc` | `LANG` / `LC_ALL` / `LC_CTYPE` = `en_US.UTF-8` (falls back to `C.UTF-8`), and `chcp 65001` for interactive shells |
| `~/.vimrc` | `encoding`, `fileencoding`, `fileencodings` (including `cp1258` for legacy Windows-Vietnamese files), `termencoding` |
| `~/.inputrc` | `input-meta` / `output-meta` on, `convert-meta` off, keeping `$include /etc/inputrc` |
| `~/.minttyrc` | `Charset=UTF-8`, `Locale=en_US`, and `Font` if it was unset |
| `git --global` | `core.quotepath false`, `i18n.commitencoding`, `i18n.logoutputencoding`, `gui.encoding` |
| `HKCU\Console` | `CodePage=65001` and `FaceName`, including the per-title subkeys that override the root value |
| PowerShell profile | `[Console]::OutputEncoding` / `InputEncoding` and `$OutputEncoding` set to UTF-8 |

The profile path comes from `$PROFILE.CurrentUserAllHosts`, so a `Documents`
folder redirected to OneDrive is handled correctly.

Restart Git Bash afterwards — the locale only applies to new shells.

## Safety

Every block is guarded by a `lazy-cli UTF-8` marker, so running the command twice
changes nothing. Files that already existed are copied to `<file>.lazy.bak` before
the first edit; files the command creates itself are not backed up.

## Undo

Delete the `lazy-cli UTF-8` blocks (or restore the `.lazy.bak` files), then:

```bash
reg.exe delete "HKCU\Console" //v CodePage //f
git config --global --unset core.quotepath
```

## Platforms

Git Bash / MSYS only. On Linux and WSL the command reports that UTF-8 is already
the default and exits without touching anything.

Windows Terminal ignores `~/.minttyrc`. If text is still wrong there, set the
profile font under Settings → Profiles → Appearance.
