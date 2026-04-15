# CoolifyBR - Coolify Backup & Restore Tool

Back up your Coolify instances — **fully**, **per-project**, or **selectively** — and migrate them to another server.

> 🇹🇷 [Türkçe dokümantasyon için buraya tıklayın / Click for Turkish documentation](README_TR.md)

---

## Features

- **Unified CLI**: One `coolifybr` entrypoint for backup, restore, remote pull jobs, verification, and installation
- **Bootstrap Installer**: Install scripts, CLI symlink, and example config files with one command
- **3 Backup Modes**: Full (entire instance), Project (per-project), Selective (per-resource)
- **PostgreSQL Database**: Full dump or per-project JSON export of the Coolify database
- **Docker Volumes**: Automatic discovery and backup of application data volumes
- **SSH Keys**: Secure transfer of Coolify SSH keys with authorized_keys merging
- **APP_KEY Management**: Automatic APP_PREVIOUS_KEYS update on restore
- **Proxy Config**: Traefik/Caddy configuration backup
- **Remote Transfer**: Automatic SCP/rsync transfer to destination server
- **Remote Pull Automation**: Schedule backups from a separate backup host that connects to the source server, runs the backup, and pulls archives back
- **Multi-Server Pull Jobs**: Run and schedule multiple remote backup jobs from one backup host
- **Pulled Snapshot Verification**: Validate pulled manifests, database dumps, and volume archives after each run
- **Coolify API Integration**: API-driven project and resource discovery
- **Interactive & CLI**: Both menu-based and command-line flag usage

## Requirements

- Linux server (with Coolify installed)
- Root access
- Docker
- `jq`, `curl`, `tar`, `gzip`
- For remote transfer: `ssh`, `scp` or `rsync`

## Quick Start

```bash
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR
./scripts/install.sh --profile source-server
coolifybr help
```

For a backup host / NAS:

```bash
./scripts/install.sh --profile backup-host
```

Detailed installer docs: [docs/INSTALL.md](docs/INSTALL.md)

## Scheduled Pull Backups

If you want a NAS or backup server to periodically connect to a remote Coolify host, trigger a backup there, and pull the archive back, use the automation files documented in [docs/REMOTE_PULL_AUTOMATION.md](docs/REMOTE_PULL_AUTOMATION.md).

Common commands:

```bash
coolifybr backup --mode full
coolifybr restore --file /tmp/backup.tar.gz
coolifybr pull-run
coolifybr pull-run-jobs
coolifybr pull-verify /srv/backups/app
```

---

# Backup Setup (Source Server)

Run these steps on the server **where Coolify is currently running** and you want to take a backup from.

## 1. Install CoolifyBR

```bash
ssh root@YOUR_SOURCE_SERVER
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR
./scripts/install.sh --profile source-server
```

## 2. (Optional) Configure API Token

CoolifyBR can discover your projects via the Coolify API. This is optional — if no token is set, the tool falls back to direct database queries.

```bash
cp config.env config.local.env
nano config.local.env
```

Set the following value (get your token from **Coolify Dashboard → Keys & Tokens → API Tokens**):

```
COOLIFY_API_TOKEN=your-api-token-here
```

> The Coolify configuration file is located at `/data/coolify/source/.env`. CoolifyBR reads APP_KEY and other settings from this file automatically.

## 3. Run a Backup

### Full Instance Backup

Backs up the entire Coolify instance: database, all Docker volumes, SSH keys, environment config, and proxy settings.

```bash
sudo coolifybr backup --mode full
```

### Project Backup

Backs up one or more specific projects. An interactive menu lets you pick which projects to include.

```bash
sudo coolifybr backup --mode project
sudo coolifybr backup --mode project --project-uuid abc-123-def
```

### Selective Backup

Choose exactly what to include: database, specific container volumes, SSH keys, environment.

```bash
sudo coolifybr backup --mode selective
```

### Backup Options

```
Modes:
  --mode full          Full Coolify instance (DB + volumes + SSH + proxy)
  --mode project       Backup specific project(s)
  --mode selective     Interactive resource selection

Options:
  --output DIR         Output directory (default: ./backups)
  --project-uuid UUID  Project UUID (skip interactive selection in project mode)
  --transfer HOST      Transfer backup to remote host after creation
  --transfer-user USER Remote SSH user (default: root)
  --transfer-key PATH  SSH key for remote transfer
  --transfer-port PORT Remote SSH port (default: 22)
  --skip-volumes       Skip Docker volume backups
  --skip-db            Skip database backup
  --non-interactive    Run without prompts (use defaults)
```

## 4. Transfer to Destination Server

After the backup is created, you need to transfer the `.tar.gz` archive to the target server.

### Option A: Manual SCP

```bash
scp backups/coolify-backup-full-20260308-143000.tar.gz root@NEW_SERVER:/tmp/
```

### Option B: Automatic Transfer (built-in)

CoolifyBR can transfer the backup directly after creation:

```bash
sudo coolifybr backup --mode full --transfer 192.168.1.100
```

With custom SSH settings:

```bash
sudo coolifybr backup --mode full \
  --transfer 192.168.1.100 \
  --transfer-user root \
  --transfer-key ~/.ssh/id_rsa \
  --transfer-port 22
```

This uses rsync if available, otherwise falls back to SCP. The tool will also offer to run the restore on the remote server automatically.

---

# Restore Setup (Destination Server)

Run these steps on the **new/target server** where you want to restore Coolify.

## 1. Install Coolify on the Target Server

Coolify must be installed **before** restoring. Install the same (or compatible) version:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Wait for Coolify to fully start. Verify it is running:

```bash
docker ps --filter "name=coolify"
```

You should see `coolify`, `coolify-db`, `coolify-redis`, `coolify-realtime`, and `coolify-proxy` containers.

## 2. Install CoolifyBR on the Target Server

```bash
ssh root@YOUR_TARGET_SERVER
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR
./scripts/install.sh --profile source-server
```

## 3. Copy the Backup Archive

If you haven't already transferred the backup:

```bash
# From your local machine or source server
scp /path/to/coolify-backup-full-20260308-143000.tar.gz root@TARGET_SERVER:/tmp/
```

## 4. Run the Restore

```bash
sudo coolifybr restore --file /tmp/coolify-backup-full-20260308-143000.tar.gz
```

The restore script will:

1. Extract the backup archive
2. Read the manifest and display backup info
3. Stop Coolify containers (keeps `coolify-db` running)
4. Restore the PostgreSQL database from the dump
5. Restore all Docker volumes
6. Restore SSH keys and merge authorized_keys
7. Update `APP_PREVIOUS_KEYS` in `/data/coolify/source/.env` (so the old APP_KEY still works)
8. Restore proxy (Traefik/Caddy) configuration
9. Restart all Coolify containers

### Restore Options

```
Options:
  --file PATH          Path to backup archive (.tar.gz)
  --mode MODE          Restore mode: full, selective (default: auto-detect from manifest)
  --skip-volumes       Skip Docker volume restore
  --skip-db            Skip database restore
  --skip-ssh           Skip SSH key restore
  --skip-env           Skip .env restore
  --skip-proxy         Skip proxy configuration restore
  --skip-restart       Skip Coolify restart after restore
  --non-interactive    Run without prompts (restore everything)
```

### Selective Restore

If you only want to restore specific parts:

```bash
sudo coolifybr restore --file /tmp/backup.tar.gz --skip-volumes --skip-ssh --skip-proxy
sudo coolifybr restore --file /tmp/backup.tar.gz --mode selective
sudo coolifybr restore --file /tmp/backup.tar.gz --non-interactive
```

## 5. Post-Restore Verification

After restore completes:

1. **Open your Coolify dashboard** and verify you can log in
2. **Check projects and deployments** are visible and correct
3. **Test SSH connections** to managed servers (Settings → SSH Keys)
4. **Re-deploy applications** if any containers are not running
5. **Update DNS records** if the server IP has changed

---

## Backup Archive Structure

```
coolify-backup-full-20260308-143000.tar.gz
├── manifest.json           # Metadata (mode, date, version, components)
├── database/
│   └── coolify-db.dump     # PostgreSQL dump (custom format)
├── volumes/
│   ├── vol1-backup.tar.gz  # Docker volume backups
│   └── vol2-backup.tar.gz
├── ssh/
│   └── keys/               # SSH key files
├── env/
│   └── .env                # Copy of /data/coolify/source/.env (includes APP_KEY)
└── proxy/
    └── proxy-config.tar.gz # Traefik/Caddy config
```

## Manual Restore (Without CoolifyBR)

If you cannot use the restore script, do it manually:

1. **Install Coolify on the target server** (same version)
2. **Stop Coolify containers**: `docker stop coolify coolify-redis coolify-realtime`
3. **Restore the DB**:
   ```bash
   cat coolify-db.dump | docker exec -i coolify-db pg_restore \
     --verbose --clean --no-acl --no-owner -U coolify -d coolify
   ```
4. **Copy SSH keys** into `/data/coolify/ssh/keys/` and set permissions:
   ```bash
   chmod 600 /data/coolify/ssh/keys/*
   ```
5. **Set APP_KEY** — add the old APP_KEY to `/data/coolify/source/.env`:
   ```bash
   echo "APP_PREVIOUS_KEYS=old_key_from_backup" >> /data/coolify/source/.env
   ```
6. **Restart Coolify**:
   ```bash
   cd /data/coolify/source && docker compose up -d
   ```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| 500 error on login | Ensure `APP_PREVIOUS_KEYS` is set correctly in `/data/coolify/source/.env` |
| Permission denied | Run `sudo chown -R root:root /data/coolify` |
| Cannot SSH to managed servers | Verify SSH keys were restored correctly under `/data/coolify/ssh/keys/` |
| Docker volumes not restoring | Ensure Docker is running on the target server |
| API token error | Check the token in `config.env` |
| Database restore fails | Make sure `coolify-db` container is running: `docker start coolify-db` |
| Coolify won't start after restore | Run `cd /data/coolify/source && docker compose up -d` |

---

## License

MIT License
