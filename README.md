# CoolifyBR - Coolify Backup & Restore Tool

Back up your Coolify instances — **fully**, **per-project**, or **selectively** — and migrate them to another server.

> 🇹🇷 [Türkçe dokümantasyon için buraya tıklayın / Click for Turkish documentation](README_TR.md)

---

## Features

- **3 Backup Modes**: Full (entire instance), Project (per-project), Selective (per-resource)
- **PostgreSQL Database**: Full dump or per-project JSON export of the Coolify database
- **Docker Volumes**: Automatic discovery and backup of application data volumes
- **SSH Keys**: Secure transfer of Coolify SSH keys with authorized_keys merging
- **APP_KEY Management**: Automatic APP_PREVIOUS_KEYS update on restore
- **Proxy Config**: Traefik/Caddy configuration backup
- **Remote Transfer**: Automatic SCP/rsync transfer to destination server
- **Coolify API Integration**: API-driven project and resource discovery
- **Interactive & CLI**: Both menu-based and command-line flag usage

## Requirements

- Linux server (with Coolify installed)
- Root access
- Docker
- `jq`, `curl`, `tar`, `gzip`
- For remote transfer: `ssh`, `scp` or `rsync`

## Installation

```bash
# Clone the repository
git clone https://github.com/oguzdelioglu/CoolifyBR.git
cd CoolifyBR

# Make scripts executable
chmod +x coolify-backup.sh coolify-restore.sh

# (Optional) Set your API token
cp config.env config.local.env
nano config.local.env  # Enter your COOLIFY_API_TOKEN
```

## Quick Start

### Full Backup

```bash
sudo ./coolify-backup.sh --mode full
```

### Project Backup

```bash
# Interactive project selection
sudo ./coolify-backup.sh --mode project

# With a specific project UUID
sudo ./coolify-backup.sh --mode project --project-uuid abc-123-def
```

### Selective Backup

```bash
sudo ./coolify-backup.sh --mode selective
```

### Restore from Backup

```bash
# Copy the backup to the target server
scp backups/coolify-backup-full-20260308-143000.tar.gz root@new-server:/tmp/

# Restore on the target server
sudo ./coolify-restore.sh --file /tmp/coolify-backup-full-20260308-143000.tar.gz
```

### Direct Transfer + Restore

```bash
# Backup and transfer to remote server
sudo ./coolify-backup.sh --mode full --transfer 192.168.1.100

# With custom SSH settings
sudo ./coolify-backup.sh --mode full \
  --transfer 192.168.1.100 \
  --transfer-user root \
  --transfer-key ~/.ssh/id_rsa \
  --transfer-port 22
```

---

## Usage Reference

### coolify-backup.sh

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

### coolify-restore.sh

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

## Manual Restore Steps

If you cannot use the script, restore manually:

1. **Install Coolify on the target server** (same version)
2. **Stop Coolify containers**: `docker stop coolify coolify-redis coolify-realtime`
3. **Restore the DB**: `cat coolify-db.dump | docker exec -i coolify-db pg_restore --verbose --clean --no-acl --no-owner -U coolify -d coolify`
4. **Copy SSH keys** into `/data/coolify/ssh/keys/`
5. **Set APP_KEY**: Add `APP_PREVIOUS_KEYS=old_key` to `/data/coolify/source/.env`
6. **Restart Coolify**: `curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| 500 error on login | Ensure `APP_PREVIOUS_KEYS` is set correctly in `/data/coolify/source/.env` |
| Permission denied | Run `sudo chown -R root:root /data/coolify` |
| Cannot SSH to managed servers | Verify SSH keys were restored correctly |
| Docker volumes not restoring | Ensure Docker is running on the target server |
| API token error | Check the token in `config.env` |

---

## License

MIT License
