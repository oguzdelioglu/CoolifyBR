# Remote Pull Automation

This repository includes a pull-based automation flow for backing up one or more remote Coolify servers on a schedule.

## What it does

- Connects from your backup host to the remote Coolify server over SSH
- Uploads the current repository contents to the remote server
- Runs `coolify-backup.sh` remotely in `full`, `project`, or `selective` mode
- Pulls the resulting archive back to your backup host
- Extracts the archive into separate `files/`, `db/`, and `docker/` snapshot trees
- Verifies the pulled snapshot and volume archives
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
- `ops/run-remote-pull-jobs.sh`: runs every job config in a directory
- `ops/install-remote-pull-jobs-cron.sh`: installs one cron line per job config
- `ops/verify-remote-pull-backup.sh`: verifies a pulled snapshot
- `scripts/init-job.sh`: creates a new external job config scaffold
- `scripts/doctor.sh`: checks backup-host readiness

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

Or use the unified CLI:

```bash
coolifybr doctor --profile backup-host
coolifybr init job --name app-1
coolifybr pull run
coolifybr cron install
```

## Multi-server usage

Place one config per source server in a directory such as:

- `/root/.config/coolifybr/jobs/app-1.env`
- `/root/.config/coolifybr/jobs/app-2.env`

Then either:

- run them all manually with `./ops/run-remote-pull-jobs.sh`
- or install cron entries for all of them with `./ops/install-remote-pull-jobs-cron.sh`

Each job config can define its own:

- `BACKUP_JOB_NAME`
- `LOCAL_BACKUP_ROOT`
- `SCHEDULE_HOUR`
- `SCHEDULE_MINUTE`
- `REMOTE_HOST`
- `REMOTE_KEY_PATH`

## Notes

- If SSH key auth is not active yet, the script can bootstrap `authorized_keys` using `REMOTE_PASSWORD`
- `VERIFY_AFTER_PULL=true` verifies manifest, inventory, database outputs, and local volume archives after each run
- `DELETE_REMOTE_ARCHIVE_AFTER_PULL=true` removes the remote archive after a successful pull
- `DELETE_LOCAL_ARCHIVE_AFTER_EXTRACT=true` removes the locally pulled `.tar.gz` after extraction to save disk space
- `REMOTE_BACKUP_EXTRA_ARGS` lets you pass extra flags to `coolify-backup.sh` on the remote host
- The remote server must already satisfy the normal CoolifyBR backup requirements
- For public repositories, keep server-specific wrapper scripts and real config files only on your own infrastructure
