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

## Safety

Nothing is written unless the credential actually works. Only the repo-local
store is touched — the global and system credential helpers are never modified.
The store file lives inside `.git/`, so it is never committed.

SSH remotes are reported as "nothing to store" since they authenticate with keys.

## Undo

```bash
git config --local --unset credential.helper
rm -f .git/.git-credentials
```
