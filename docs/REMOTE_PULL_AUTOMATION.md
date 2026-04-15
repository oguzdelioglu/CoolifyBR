# Remote Pull Automation

This repository includes a pull-based automation flow for backing up a remote Coolify server on a schedule.

## What it does

- Connects from your backup host to the remote Coolify server over SSH
- Uploads the current repository contents to the remote server
- Runs `coolify-backup.sh` remotely in `full`, `project`, or `selective` mode
- Pulls the resulting archive back to your backup host
- Extracts the archive into separate `files/`, `db/`, and `docker/` snapshot trees
- Applies retention rules for daily, weekly, and monthly snapshots

## Public repo safety

- Commit only `ops/remote-pull-backup.env.example`
- Keep the live config outside the repository, for example:
  - `/root/.config/coolifybr/remote-pull-backup.env`
- Never commit passwords, private keys, hostnames, IPs, or live backup paths unless they are intentionally public

## Files

- `ops/remote-pull-backup.sh`: main automation entrypoint
- `ops/remote-pull-backup.env.example`: example config
- `ops/install-remote-pull-cron.sh`: installs the recurring cron job

## First-time setup

1. Copy `ops/remote-pull-backup.env.example` to `/root/.config/coolifybr/remote-pull-backup.env`
2. Fill in your real host, SSH key, destination path, and retention values
3. Create or place the SSH key referenced by `REMOTE_KEY_PATH`
4. Optionally set `REMOTE_HOST_FINGERPRINT` to enforce host identity
5. Run:

```bash
CONFIG_FILE=/root/.config/coolifybr/remote-pull-backup.env ./ops/remote-pull-backup.sh
```

6. Install cron:

```bash
CONFIG_FILE=/root/.config/coolifybr/remote-pull-backup.env ./ops/install-remote-pull-cron.sh
```

## Notes

- If SSH key auth is not active yet, the script can bootstrap `authorized_keys` using `REMOTE_PASSWORD`
- The remote server must already satisfy the normal CoolifyBR backup requirements
- For public repositories, keep server-specific wrapper scripts and real config files only on your own infrastructure
