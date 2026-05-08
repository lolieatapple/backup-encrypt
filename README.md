# backup-encrypt

Interactive installer for daily encrypted backups on Ubuntu.

Wraps `tar` + `gpg --symmetric` (AES-256) into a small managed cron job. One
command walks you through picking a source directory, an output directory,
an encryption password, and a UTC schedule, then installs the runtime
script, the password file, and the cron entry for you.

## Features

- **GPG AES-256** symmetric encryption with a passphrase file (chmod 600)
- **UTC-anchored cron** — the cron block declares `CRON_TZ=UTC` so the time
  you pick is the time it runs, regardless of system timezone
- **Multiple jobs** — each job has its own name, script, password file, log,
  and cron block; reinstalling the same name overwrites cleanly
- **Atomic writes** — backups are written to `<file>.partial` and renamed
  only on success, so a half-done file never poses as a valid backup
- **Retention** — old archives older than N days are pruned automatically
- **Fail loud** — missing source dir, wrong password-file permissions, or a
  failed pipe stage all exit non-zero rather than silently producing a
  broken archive
- **Uninstall** — single flag removes the script, password file, and cron
  block (backup artifacts are kept on purpose)

## Requirements

- Ubuntu (or any Debian-based distro with `apt-get`)
- Root privileges (uses `/usr/local/bin`, `/etc`, root crontab)
- `gnupg`, `tar`, `cron` — the installer offers to `apt-get install` them
  if missing

## Install

```bash
sudo ./install-backup-encrypt.sh
```

The wizard prompts for:

| Field           | Default                | Notes                                  |
| --------------- | ---------------------- | -------------------------------------- |
| Job name        | `keystore`             | `[A-Za-z0-9_-]+`, used as filename tag |
| Source dir      | `/root/osm/keystore`   | Must exist                             |
| Destination dir | `/root/encrypt-backup` | Created if missing, chmod 700          |
| UTC time        | `10:00`                | `HH:MM`, 24-hour                       |
| Retention days  | `30`                   | `0` disables pruning                   |
| Password        | —                      | Hidden, confirmed twice, min 8 chars   |

## What it installs

| Path                                          | Purpose                          |
| --------------------------------------------- | -------------------------------- |
| `/usr/local/bin/backup-encrypt-<name>.sh`     | Generated runtime backup script  |
| `/etc/backup-encrypt/<name>.pass`             | Passphrase file (chmod 600)      |
| `/var/log/backup-encrypt-<name>.log`          | Append-only log                  |
| Root crontab block tagged `backup-encrypt:<name>` | The schedule                 |

Each successful run produces:

```
/<dest>/<name>-YYYYMMDD-HHMMSS.tar.gz.gpg
```

## Restore

```bash
gpg --decrypt --batch --passphrase-file /etc/backup-encrypt/<name>.pass \
    /<dest>/<name>-YYYYMMDD-HHMMSS.tar.gz.gpg | tar -xzf -
```

If you only have the password (no passphrase file), drop `--batch
--passphrase-file ...` and `gpg` will prompt interactively.

## Uninstall

```bash
sudo ./install-backup-encrypt.sh --uninstall <name>
```

Removes the runtime script, password file, and cron block. **Existing
backup archives are left in place** — delete them manually if you want
them gone.

## Security notes

- The passphrase lives at `/etc/backup-encrypt/<name>.pass` with mode 600.
  The runtime script refuses to run if it finds anything more permissive.
- Lose this file and you lose the ability to decrypt. Store the password
  somewhere safe (password manager, sealed envelope, etc.).
- `--batch --passphrase-file` is used so the password never appears on the
  command line or in process listings.
- Archives are written with mode 600.

## License

MIT
