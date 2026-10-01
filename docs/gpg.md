# `lazy gpg`

Decrypts a GPG-encrypted file and saves the plaintext in the same directory.

```bash
lazy gpg
# Encrypted file path: /home/me/Documents/report.pdf.gpg

lazy gpg /home/me/Documents/report.pdf.gpg
```

With no argument, the command asks for the encrypted file path. Paths pasted
with matching single or double quotes are accepted. GnuPG then asks for the
passphrase through its secure `pinentry` prompt when one is required. A key
that is already unlocked in `gpg-agent` might not require another prompt.

## Output name

The result is always stored beside the encrypted file:

| Input | Output |
|---|---|
| `report.pdf.gpg` | `report.pdf` |
| `archive.pgp` | `archive` |
| `secrets.asc` | `secrets` |
| `encrypted-file` | `encrypted-file.decrypted` |

The suffix matching is case-insensitive. The encrypted source file is kept.

## ZIP extraction

When the decrypted result is a ZIP archive, the command asks whether to extract
it:

```text
The decrypted file is a ZIP. Unzip it now? [y/N]: y
Extracting to: /home/me/Documents/archive
```

Choosing `y` extracts `archive.zip` into a sibling `archive/` directory. For a
ZIP without a `.zip` suffix, the directory receives an `.unzipped` suffix. The
decrypted ZIP itself is kept. Choosing `n`, pressing Enter, or reaching end of
input skips extraction.

If the ZIP is password-protected, `unzip` asks for the password without `lazy`
putting it in a command-line argument or storing it. An existing destination
directory is never overwritten.

## GZIP decompression

GZIP output is also detected by its `.gz` suffix or file signature:

```text
The decrypted file is GZIP data. Decompress it now? [y/N]: y
Decompressing to: /home/me/Documents/database.sql
```

Choosing `y` decompresses `database.sql.gz` into the sibling file
`database.sql`. An `archive.tar.gz` becomes `archive.tar`; this command does not
automatically unpack that TAR archive. When GZIP data has no `.gz` suffix, the
output receives a `.decompressed` suffix. The decrypted `.gz` file is kept.

Unlike ZIP, the GZIP format has no password-protection feature, so there is no
second password prompt for this step.

## Requirements

The `gpg` command must be installed and available on `PATH`:

- Debian/Ubuntu/WSL: `sudo apt install gnupg`
- macOS: `brew install gnupg`
- Git Bash: install Gpg4win and make its `gpg` command available in Git Bash

Optional ZIP extraction also requires `unzip`. It is available by default on
macOS; install it with `sudo apt install unzip` on Debian/Ubuntu/WSL or
`scoop install unzip` for Git Bash on Windows.

GZIP decompression requires the `gzip` command, which is normally included on
Linux, WSL, macOS, and Git Bash.

## Safety and failures

An existing output file is never overwritten. Move or rename it before retrying.
The plaintext is first written with private permissions inside a temporary
directory next to the destination, then moved into place only after GnuPG
finishes successfully. A wrong passphrase, cancellation, or GnuPG error removes
the temporary output.

ZIP contents are also extracted into a private temporary directory first. A
wrong ZIP password, cancellation, or extraction error removes that directory
while retaining the successfully decrypted ZIP for retrying.

GZIP output follows the same rule: failed decompression removes its partial
temporary file and retains the decrypted `.gz` file.

The passphrase is handled by GnuPG and is never passed as a command-line
argument or stored by `lazy`.

## Undo

Delete the decrypted output file and, when created, its extracted sibling
directory. The original `.gpg`, `.pgp`, or `.asc` file is unchanged.
