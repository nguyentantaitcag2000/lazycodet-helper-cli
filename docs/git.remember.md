# `lazy git.remember`

Stores the Git username and password/token for the current repository so Git
stops asking on every push and pull.

```bash
lazy git.remember              # authenticate against origin
lazy git.remember upstream     # another remote
lazy git.remember -f           # replace the credential already stored
```

## How it works

It first checks whether the repository can already authenticate with the remote.
If it can, it says so and stops. If it cannot, it asks for the username and
password/token, verifies them against the remote, and only then saves them:

```bash
git config --local credential.helper "store --file=.git/.git-credentials"
```

A wrong password is caught during verification and re-prompted, up to 3 attempts.

## Example

```
Remote:  origin -> https://github.com/acme/web.git
No credential stored for github.com yet.

Note: use a personal access token as the password — github.com rejects account passwords.

Attempt 1/3
Username: acme-bot
Password / token (hidden):
Verifying against github.com ... failed

Authentication failed — wrong username or password/token.

Attempt 2/3
Username [acme-bot]:
Password / token (hidden):
Verifying against github.com ... ok

Saved. Git will no longer ask for this repository.
```

## When the directory is not a repository yet

Instead of failing, it asks for the repository URL and clones it once the
credential checks out:

```
This directory is not a Git repository yet:
  /home/me/code

Enter the repository URL to authenticate against. Once the credential
checks out, the repository is cloned into a subdirectory here and the
credential is stored inside that clone.

Repository URL: https://github.com/acme/web.git
Username: acme-bot
Password / token (hidden):
Verifying against github.com ... ok

Clone into directory [web]:

Cloning https://github.com/acme/web.git into 'web' ...
```

The clone reuses the credential that was just verified, so it never asks again,
and the credential is stored inside the new clone — not in the directory you
started from. The URL is re-prompted if it is not `http(s)` or has no host. When
only the URL-embedded fallback works, the remote URL is rewritten afterwards so
no password is left behind in `.git/config`.

## Other cases it handles

| Situation | What happens |
|---|---|
| Repository exists but has no remote | The URL you enter is added as the remote |
| Repository exists but has no commits (unborn `HEAD`) | Offers to `git fetch` and check out the remote's default branch, falling back to `main` / `master` / the first remote branch |
| A credential for the host already works | Reused instead of asking again |
| Named remote does not exist, but others do | Errors and lists the available remotes |
| SSH remote | Reported as "nothing to store" — SSH authenticates with keys |

## Guards

The checkout of an unborn repository lands in the *current* directory, so it is
only offered when the worktree holds nothing but `.git`:

- A worktree rooted at `$HOME` is reported as a `.git` created by accident, with
  the `rm -rf` command to undo it.
- Any other worktree that already has files in it just prints the manual
  `git fetch` command.
- An existing non-empty clone target stops the run with a
  `cd <dir> && lazy git.remember` hint instead of clobbering it.

Neither case touches the directory. Declining the offer, a remote with no
branches, or a missing terminal all exit 0 after printing the hint.

## Safety

Nothing is written unless the credential actually works. Only the repo-local
store is touched — the global and system credential helpers are never modified.
The store file lives inside `.git/`, so it is never committed.

## Undo

```bash
git config --local --unset credential.helper
rm -f .git/.git-credentials
```
