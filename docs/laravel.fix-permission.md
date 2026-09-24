# `lazy laravel.fix-permission`

Makes a Laravel project's `storage/` and `bootstrap/cache/` writable by both you
and the PHP process, for the files that exist now and for every file created
later, without leaving mode changes that Git reports.

```bash
lazy laravel.fix-permission            # the project here, or the one below this directory
lazy laravel.fix-permission --check    # report only, exit 1 if anything is wrong
lazy laravel.fix-permission path/to/api -y
lazy laravel.fix-permission --group www-data
lazy laravel.fix-permission --container my-php-container
```

## Why not `chmod -R 775`

The usual one-liners each break something:

| Command | What goes wrong |
|---|---|
| `chmod -R 775 storage` / `chmod -R 755 storage` | Plain files get the execute bit. Git tracks that bit, so every tracked `.gitignore` under `storage/` and `bootstrap/cache/` shows up as modified. |
| `chmod -R a+rwX storage` | World-writable, and only fixes files that exist today. |
| `chmod -R 777 storage` | Both of the above. |

All of them only fix the files that exist when you run them. The next
`laravel-YYYY-MM-DD.log` is created by whoever writes first, with their umask
(usually `644`). If that is `php artisan` run as root through `docker exec`,
php-fpm (`www-data`) can no longer write to it and Laravel fails to log the
error. If it is php-fpm, you can no longer edit it in your editor.

## What it sets

| What | Value | Why |
|---|---|---|
| Owner | you (`$SUDO_USER` under sudo) | so your editor can write |
| Group | the group PHP runs as | so php-fpm / Apache / artisan can write |
| Directories | `2775` | setgid: new files inherit the PHP group whoever creates them |
| Files | `664` | read and write, never executable |
| Files that `HEAD` tracks as executable | `775` | their mode is kept as committed |
| Default ACL on directories | `user:<you>:rw`, `group:<php>:rw` | files created later are writable by both sides, whatever the creator's umask |

`664` and `644` are the same to Git, which only records the execute bit, so the
command never adds Git-visible changes. Symlinks are not followed.

## How the PHP group is found

In order, the first that applies wins:

1. `--group <name|gid>`.
2. `--container <name>`: the PHP processes in that Docker container.
3. A running Docker container that bind-mounts the project: the group of its
   PHP worker processes (`php-fpm`, `php`, `frankenphp`, `httpd`, `apache2`,
   `rr`, `swoole`). The php-fpm master runs as root and is ignored; nginx is
   ignored because it never writes to `storage/`. The numeric gid is read with
   `docker top`, so it works even when the image has no `ps`, and it does not
   need a matching group name on the host.
4. PHP processes running directly on this machine. Processes that belong to a
   container are skipped, because on Linux and WSL the host's `ps` lists them
   too, and they belong to some other project.
5. Your own group, when nothing is running (for example `php artisan serve` or
   the test suite runs as you).

## Finding the project

It walks up from the given path (default `.`) looking for `artisan` next to
`bootstrap/app.php`, so it works from anywhere inside the project. If there is
none above, it searches up to four levels down, which covers running it from a
monorepo root. When it finds several projects there, it lists them and asks for
the path.

## Example

```
Project:  /home/me/shop/api
Paths:    storage bootstrap/cache
Owner:    me
Group:    www-data  (PHP processes in container 'shop-api', which mounts this project)
ACL:      default ACL for me and www-data on every directory

Found:
    2  not in group www-data
         e.g. storage/framework/cache/data/9a/58/9a58...
   17  files with an execute bit (shows up as a Git mode change)
         e.g. storage/logs/.gitignore
   25  directories without the default ACL for files created later
         e.g. storage

This needs root (files owned by someone else, or a group you are not in); sudo will ask.

Apply these permissions? [y/N] y

Applying:
  chown -R me:www-data
  directories -> 2775
  files -> 664
  ACL: me and www-data rw on existing files, inherited by new ones

Done. You and www-data can both write to storage bootstrap/cache.
```

## Root

`sudo` is used only when it is needed: changing files someone else owns, or
giving them a group you are not a member of. Otherwise it runs as you.

## Without ACL support

The default ACL needs `setfacl`/`getfacl` (the `acl` package, e.g.
`sudo apt-get install acl`). Without it the existing files are still fixed and
setgid still hands new files the PHP group, but their mode depends on the
creator's umask again. The command says so and, when `config/logging.php` has no
`'permission'` key, suggests giving the log channels an explicit mode:

```php
'daily' => [
    // ...
    'permission' => 0664,
],
```

## Staged mode changes

Fixing the working tree does not unstage a mode change that was already staged
(for example after a `chmod -R 755` followed by `git add`). The command detects
that and prints the command to undo it:

```bash
git -C <project> restore --staged -- storage bootstrap/cache
```

## Platforms

Linux and WSL. On WSL, the project must live in the Linux filesystem: on a
Windows drive (`/mnt/c`, `/mnt/d`, a `9p`/`drvfs` mount) chown and chmod have no
real effect, so the command stops and says so. macOS is not implemented yet, and
Git Bash is excluded; see [platform support](platform-support.md).

## Undo

There is nothing Laravel-specific to restore. To drop the ACLs:

```bash
setfacl -R -b storage bootstrap/cache
```
