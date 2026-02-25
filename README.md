# Mailcow Backup

A modular, remote backup agent for [Mailcow Dockerized](https://mailcow.email/) installations. Runs on your **backup server**, SSHes into one or more Mailcow hosts, triggers the upstream `backup_and_restore.sh` helper, then downloads the resulting backup via rsync.

## Features

- **Modular design** – functionality split across small, focused library files
- **Multi-server support** – back up multiple Mailcow instances from one place
- **SSH key & password auth** – both methods supported (`sshpass` for password)
- **Remote execution** – invokes the official Mailcow backup script with full component and thread support
- **rsync transfer** – efficient incremental download of backup data
- **Retention management** – configurable per-server backup count
- **Colored, structured logging** – console output + persistent log file
- **Non-interactive / cron-friendly** – all prompts eliminated via environment variables

## Project Structure

```
mailcow-backup.sh          # Main entry point
config/
  backup.conf              # Global settings (backup root, retention, SSH timeout …)
  servers.conf             # Per-server configuration (SSH credentials, paths …)
lib/
  colors.sh                # Terminal color constants
  logging.sh               # log_info / log_error / log_section helpers
  config.sh                # Config loading, parsing, and validation
  ssh.sh                   # SSH execution and rsync-over-SSH utilities
  backup.sh                # Core backup workflow (preflight → remote run → download)
  cleanup.sh               # Local retention / listing utilities
logs/                      # Runtime log files (gitignored)
backups/                   # Downloaded backup archives (gitignored)
```

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/RyderAsKing/Mailcow-backup.git
cd Mailcow-backup

# 2. Make the script executable
chmod +x mailcow-backup.sh

# 3. Generate default configuration files
./mailcow-backup.sh --create-config

# 4. Edit server configuration
nano config/servers.conf

# 5. Test SSH connectivity
./mailcow-backup.sh test production

# 6. Run a backup
./mailcow-backup.sh backup production
```

## Prerequisites

| Requirement                 | Where                  | Notes                                             |
| --------------------------- | ---------------------- | ------------------------------------------------- |
| `bash` ≥ 4.0                | backup server          |                                                   |
| `rsync`                     | backup server & remote | for file transfer                                 |
| `ssh` / `sshpass`           | backup server          | `sshpass` only for password auth                  |
| `docker` / `docker compose` | remote mailcow server  | to run mailcow                                    |
| Mailcow installed           | remote mailcow server  | `helper-scripts/backup_and_restore.sh` must exist |

Install `sshpass` for password authentication:

```bash
# Debian / Ubuntu
sudo apt-get install sshpass

# RHEL / CentOS
sudo yum install sshpass
```

## Configuration

### `config/backup.conf` – Global settings

```bash
BACKUP_ROOT="./backups"          # Local directory for stored backups
RETENTION_COUNT=7                # Default backups to keep per server
SSH_TIMEOUT=30                   # SSH connection timeout (seconds)
REMOTE_BACKUP_PATH="/tmp/mailcow_backup"   # Staging path on remote server
MAILCOW_INSTALL_DIR="/opt/mailcow-dockerized"
BACKUP_COMPONENTS="all"          # vmail crypt redis rspamd postfix mysql all
THREADS=""                       # Optional: CPU thread count for remote backup
DELETE_DAYS=""                   # Optional: delete remote backups older than N days
```

### `config/servers.conf` – Per-server configuration

**SSH Key Authentication (recommended)**

```ini
[production]
enabled=true
ssh_host=mail.example.com
ssh_user=root
ssh_port=22
ssh_auth_method=key
ssh_key=/home/backup/.ssh/id_rsa_mailcow
mailcow_install_dir=/opt/mailcow-dockerized
remote_backup_path=/tmp/mailcow_backup
backup_components=all
retention_count=7
threads=
delete_days=
```

**SSH Password Authentication**

```ini
[production]
enabled=true
ssh_host=mail.example.com
ssh_user=root
ssh_port=22
ssh_auth_method=password
ssh_pass="your_ssh_password"
mailcow_install_dir=/opt/mailcow-dockerized
remote_backup_path=/tmp/mailcow_backup
backup_components=all
retention_count=7
```

> **Note:** `config/servers.conf` is gitignored to prevent accidental credential exposure.

## Usage

```bash
# Backup commands
./mailcow-backup.sh backup all           # Backup all enabled servers
./mailcow-backup.sh backup production    # Backup specific server

# List local backups
./mailcow-backup.sh list all
./mailcow-backup.sh list production

# Apply retention / cleanup old backups
./mailcow-backup.sh cleanup all
./mailcow-backup.sh cleanup production

# Test SSH connections
./mailcow-backup.sh test all
./mailcow-backup.sh test production

# Configuration
./mailcow-backup.sh --create-config      # Generate default configs
./mailcow-backup.sh --help               # Show help
./mailcow-backup.sh --version            # Show version
```

## Backup Workflow

For each server the following steps are performed:

1. **Pre-flight checks** – SSH connectivity, mailcow script present, rsync available
2. **Remote backup** – Runs `backup_and_restore.sh backup <components>` on the remote server with `MAILCOW_BACKUP_LOCATION` set
3. **Download** – rsync pulls the latest `mailcow_DATE` directory to `backups/<server>/<timestamp>/`
4. **Metadata** – Writes `backup_info.txt` into the local backup directory
5. **Remote cleanup** – Removes the staging directory from the remote server
6. **Retention** – Applies the configured `retention_count` locally

## Backup Structure

```
backups/
└── production/
    ├── 2025-01-20_02-05-00/
    │   ├── mailcow_data/           # Contents of the remote mailcow backup dir
    │   └── backup_info.txt         # Metadata (server, date, source, components)
    └── 2025-01-19_02-05-01/
        └── ...
```

## SSH Key Setup

```bash
# Generate a dedicated key pair
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_mailcow -C "mailcow-backup"

# Copy the public key to the remote server
ssh-copy-id -i ~/.ssh/id_ed25519_mailcow.pub root@mail.example.com

# Update servers.conf
ssh_auth_method=key
ssh_key=~/.ssh/id_ed25519_mailcow
```

## Scheduling with Cron

```cron
# Daily backup at 02:00
0 2 * * * /path/to/mailcow-backup.sh backup all >> /var/log/mailcow-backup.log 2>&1

# Weekly cleanup on Sunday at 03:00
0 3 * * 0 /path/to/mailcow-backup.sh cleanup all >> /var/log/mailcow-backup.log 2>&1
```

## Debug Mode

```bash
DEBUG=1 ./mailcow-backup.sh backup production
# or
./mailcow-backup.sh --debug backup production
```

## Security Considerations

- Use **SSH key authentication** with a dedicated, restricted key pair
- Set `chmod 600` on `config/servers.conf` to protect credentials
- The `config/servers.conf` file is listed in `.gitignore` – never commit it
- Consider running the backup user with a restricted shell on the remote server

## License

MIT License — see [LICENSE](LICENSE) for details.

Automate your Mailcow backups from a remote server. This script connects via SSH to trigger lean backups and pulls the essential recovery files to your storage server via rsync.
