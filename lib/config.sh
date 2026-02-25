#!/bin/bash
# lib/config.sh - Configuration loading and parsing

# Script root is set by main script
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MAIN_CONFIG="${SCRIPT_DIR}/config/backup.conf"
SERVERS_CONFIG="${SCRIPT_DIR}/config/servers.conf"

# ---------------------------------------------------------------------------
# load_main_config
#   Sources the main backup.conf and sets defaults for missing values.
# ---------------------------------------------------------------------------
load_main_config() {
    if [ ! -f "$MAIN_CONFIG" ]; then
        log_error "Main config not found: $MAIN_CONFIG"
        log_error "Run './mailcow-backup.sh --create-config' to generate default configs."
        return 1
    fi

    # shellcheck source=/dev/null
    source "$MAIN_CONFIG"

    # Apply defaults
    BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/backups}"
    RETENTION_COUNT="${RETENTION_COUNT:-7}"
    SSH_TIMEOUT="${SSH_TIMEOUT:-30}"
    REMOTE_BACKUP_PATH="${REMOTE_BACKUP_PATH:-/tmp/mailcow_backup}"
    MAILCOW_INSTALL_DIR="${MAILCOW_INSTALL_DIR:-/opt/mailcow-dockerized}"
    BACKUP_COMPONENTS="${BACKUP_COMPONENTS:-all}"
    THREADS="${THREADS:-}"
    DELETE_DAYS="${DELETE_DAYS:-}"

    log_debug "Main config loaded from $MAIN_CONFIG"
}

# ---------------------------------------------------------------------------
# _strip_quotes <value>
#   Strips surrounding single or double quotes from a value.
# ---------------------------------------------------------------------------
_strip_quotes() {
    local val="$1"
    # Remove surrounding double quotes
    val="${val#\"}" ; val="${val%\"}"
    # Remove surrounding single quotes
    val="${val#\'}" ; val="${val%\'}"
    echo "$val"
}

# ---------------------------------------------------------------------------
# get_server_value <server_name> <key>
#   Reads a key from the [server_name] section of servers.conf.
#   Outputs the value (stripped of quotes) or empty string if not found.
# ---------------------------------------------------------------------------
get_server_value() {
    local server="$1"
    local key="$2"
    local in_section=0
    local value=""

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            if [ "${BASH_REMATCH[1]}" = "$server" ]; then
                in_section=1
            else
                in_section=0
            fi
            continue
        fi

        if [ "$in_section" = "1" ]; then
            local k v
            k="${line%%=*}"
            v="${line#*=}"
            k="${k// /}"  # trim spaces
            if [ "$k" = "$key" ]; then
                value="$(_strip_quotes "$v")"
                break
            fi
        fi
    done < "$SERVERS_CONFIG"

    echo "$value"
}

# ---------------------------------------------------------------------------
# load_server_config <server_name>
#   Loads all values for a server section into SERVER_* variables.
# ---------------------------------------------------------------------------
load_server_config() {
    local server="$1"

    if [ ! -f "$SERVERS_CONFIG" ]; then
        log_error "Servers config not found: $SERVERS_CONFIG"
        return 1
    fi

    # Check section exists
    if ! grep -q "^\[${server}\]" "$SERVERS_CONFIG"; then
        log_error "Server '${server}' not found in $SERVERS_CONFIG"
        return 1
    fi

    SERVER_NAME="$server"
    SERVER_ENABLED="$(get_server_value "$server" "enabled")"
    SERVER_SSH_HOST="$(get_server_value "$server" "ssh_host")"
    SERVER_SSH_USER="$(get_server_value "$server" "ssh_user")"
    SERVER_SSH_PORT="$(get_server_value "$server" "ssh_port")"
    SERVER_SSH_AUTH_METHOD="$(get_server_value "$server" "ssh_auth_method")"
    SERVER_SSH_KEY="$(get_server_value "$server" "ssh_key")"
    SERVER_SSH_PASS="$(get_server_value "$server" "ssh_pass")"
    SERVER_MAILCOW_INSTALL_DIR="$(get_server_value "$server" "mailcow_install_dir")"
    SERVER_REMOTE_BACKUP_PATH="$(get_server_value "$server" "remote_backup_path")"
    SERVER_BACKUP_COMPONENTS="$(get_server_value "$server" "backup_components")"
    SERVER_RETENTION_COUNT="$(get_server_value "$server" "retention_count")"
    SERVER_DELETE_DAYS="$(get_server_value "$server" "delete_days")"
    SERVER_THREADS="$(get_server_value "$server" "threads")"

    # Fall back to global config values
    SERVER_MAILCOW_INSTALL_DIR="${SERVER_MAILCOW_INSTALL_DIR:-$MAILCOW_INSTALL_DIR}"
    SERVER_REMOTE_BACKUP_PATH="${SERVER_REMOTE_BACKUP_PATH:-$REMOTE_BACKUP_PATH}"
    SERVER_BACKUP_COMPONENTS="${SERVER_BACKUP_COMPONENTS:-$BACKUP_COMPONENTS}"
    SERVER_RETENTION_COUNT="${SERVER_RETENTION_COUNT:-$RETENTION_COUNT}"
    SERVER_DELETE_DAYS="${SERVER_DELETE_DAYS:-$DELETE_DAYS}"
    SERVER_THREADS="${SERVER_THREADS:-$THREADS}"
    SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"
    SERVER_SSH_AUTH_METHOD="${SERVER_SSH_AUTH_METHOD:-key}"

    log_debug "Server config loaded for '$server'"
}

# ---------------------------------------------------------------------------
# list_servers
#   Outputs all server names found in servers.conf.
# ---------------------------------------------------------------------------
list_servers() {
    if [ ! -f "$SERVERS_CONFIG" ]; then
        log_error "Servers config not found: $SERVERS_CONFIG"
        return 1
    fi
    grep -E '^\[[^\]]+\]$' "$SERVERS_CONFIG" | tr -d '[]'
}

# ---------------------------------------------------------------------------
# list_enabled_servers
#   Outputs only server names where enabled=true.
# ---------------------------------------------------------------------------
list_enabled_servers() {
    local all_servers
    all_servers="$(list_servers)" || return 1

    while IFS= read -r srv; do
        local enabled
        enabled="$(get_server_value "$srv" "enabled")"
        if [ "$enabled" = "true" ]; then
            echo "$srv"
        fi
    done <<< "$all_servers"
}

# ---------------------------------------------------------------------------
# validate_server_config
#   Checks required fields are set for the currently loaded server.
#   Returns 1 if validation fails.
# ---------------------------------------------------------------------------
validate_server_config() {
    local ok=0

    [ -z "$SERVER_SSH_HOST" ]  && { log_error "[$SERVER_NAME] 'ssh_host' is required"; ok=1; }
    [ -z "$SERVER_SSH_USER" ]  && { log_error "[$SERVER_NAME] 'ssh_user' is required"; ok=1; }

    if [ "$SERVER_SSH_AUTH_METHOD" = "key" ]; then
        [ -z "$SERVER_SSH_KEY" ] && { log_error "[$SERVER_NAME] 'ssh_key' is required for key auth"; ok=1; }
        if [ -n "$SERVER_SSH_KEY" ] && [ ! -f "$SERVER_SSH_KEY" ]; then
            log_error "[$SERVER_NAME] SSH key file not found: $SERVER_SSH_KEY"
            ok=1
        fi
    elif [ "$SERVER_SSH_AUTH_METHOD" = "password" ]; then
        [ -z "$SERVER_SSH_PASS" ] && { log_error "[$SERVER_NAME] 'ssh_pass' is required for password auth"; ok=1; }
        if ! command -v sshpass &>/dev/null; then
            log_error "[$SERVER_NAME] 'sshpass' is not installed (required for password auth)"
            ok=1
        fi
    else
        log_error "[$SERVER_NAME] Unknown ssh_auth_method: '$SERVER_SSH_AUTH_METHOD' (use 'key' or 'password')"
        ok=1
    fi

    return $ok
}

# ---------------------------------------------------------------------------
# create_default_config
#   Writes default backup.conf and servers.conf to the config/ directory.
# ---------------------------------------------------------------------------
create_default_config() {
    local config_dir="${SCRIPT_DIR}/config"
    mkdir -p "$config_dir"

    # ---- backup.conf ----
    if [ -f "${config_dir}/backup.conf" ]; then
        log_warn "backup.conf already exists – skipping."
    else
        cat > "${config_dir}/backup.conf" << 'EOF'
# =============================================================================
# Mailcow Backup - Main Configuration
# =============================================================================

# Local directory where backups are stored
BACKUP_ROOT="./backups"

# Default number of backups to keep per server (can be overridden per server)
RETENTION_COUNT=7

# SSH connection timeout in seconds
SSH_TIMEOUT=30

# Path on the remote server where mailcow's backup script stores its output
# The backup agent will use this as MAILCOW_BACKUP_LOCATION
REMOTE_BACKUP_PATH="/tmp/mailcow_backup"

# Default path to the mailcow-dockerized installation on the remote server
MAILCOW_INSTALL_DIR="/opt/mailcow-dockerized"

# Components to back up: vmail crypt redis rspamd postfix mysql all
BACKUP_COMPONENTS="all"

# Optional: number of CPU threads for mailcow backup (leave empty to omit)
THREADS=""

# Optional: delete remote backups older than N days (leave empty to omit)
DELETE_DAYS=""
EOF
        log_success "Created ${config_dir}/backup.conf"
    fi

    # ---- servers.conf ----
    if [ -f "${config_dir}/servers.conf" ]; then
        log_warn "servers.conf already exists – skipping."
    else
        cat > "${config_dir}/servers.conf" << 'EOF'
# =============================================================================
# Mailcow Backup - Server Configuration
# =============================================================================
# Each section defines one Mailcow server to back up.
# Section name (e.g. [production]) is used as the server identifier.
#
# SSH Key Authentication example:
# [production]
# enabled=true
# ssh_host=mail.example.com
# ssh_user=backup
# ssh_port=22
# ssh_auth_method=key
# ssh_key=/home/backup/.ssh/id_rsa_mailcow
# mailcow_install_dir=/opt/mailcow-dockerized
# remote_backup_path=/tmp/mailcow_backup
# backup_components=all
# retention_count=7
# threads=
# delete_days=
#
# SSH Password Authentication example:
# [production]
# enabled=true
# ssh_host=mail.example.com
# ssh_user=backup
# ssh_port=22
# ssh_auth_method=password
# ssh_pass="your_ssh_password"
# mailcow_install_dir=/opt/mailcow-dockerized
# remote_backup_path=/tmp/mailcow_backup
# backup_components=all
# retention_count=7
# threads=
# delete_days=

[production]
enabled=false
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
EOF
        log_success "Created ${config_dir}/servers.conf"
    fi
}
