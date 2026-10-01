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

## Requirements

The `gpg` command must be installed and available on `PATH`:

- Debian/Ubuntu/WSL: `sudo apt install gnupg`
- macOS: `brew install gnupg`
- Git Bash: install Gpg4win and make its `gpg` command available in Git Bash

## Safety and failures

An existing output file is never overwritten. Move or rename it before retrying.
The plaintext is first written with private permissions inside a temporary
directory next to the destination, then moved into place only after GnuPG
finishes successfully. A wrong passphrase, cancellation, or GnuPG error removes
the temporary output.

The passphrase is handled by GnuPG and is never passed as a command-line
argument or stored by `lazy`.

## Undo

Delete the decrypted output file. The original `.gpg`, `.pgp`, or `.asc` file
is unchanged.
