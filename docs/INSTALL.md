# Installation

CoolifyBR now ships with a unified CLI and an installer script so the common setup paths are much simpler.

## Quick install

```bash
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR
./scripts/install.sh --profile source-server
```

Or for a backup host / NAS:

```bash
./scripts/install.sh --profile backup-host
```

This installs a `coolifybr` symlink, marks the scripts executable, and copies example config files into your config home.

## Profiles

- `source-server`: backup/restore on the Coolify host itself
- `backup-host`: scheduled pull backups from another machine
- `full`: both setup types on one machine

## Installed entrypoint

After installation, use:

```bash
coolifybr help
```

Main commands:

- `coolifybr backup`
- `coolifybr restore`
- `coolifybr doctor`
- `coolifybr init job --name app-1`
- `coolifybr pull-run`
- `coolifybr pull-run-jobs`
- `coolifybr pull-install-cron`
- `coolifybr pull-install-jobs-cron`
- `coolifybr pull-verify`

## Config layout

By default the installer uses:

- `${XDG_CONFIG_HOME:-/root/.config}/coolifybr/config.env`
- `${XDG_CONFIG_HOME:-/root/.config}/coolifybr/remote-pull-backup.env`
- `${XDG_CONFIG_HOME:-/root/.config}/coolifybr/jobs/*.env`

These are copied from repo example files. Keep secrets in those external config files, not in the repository.
