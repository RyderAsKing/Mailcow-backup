#!/bin/bash
# =============================================================================
# mailcow-backup.sh - Backup agent for Mailcow Dockerized
#
# Runs on the backup server. SSHes into one or more Mailcow servers,
# triggers the upstream backup_and_restore.sh script, then downloads
# the resulting backup via rsync.
#
# Usage:
#   ./mailcow-backup.sh <command> [server|all] [options]
#
# Commands:
#   backup  <server|all>   Run backup for a specific server or all enabled servers
#   list    <server|all>   List local backups
#   cleanup <server|all>   Apply retention policy to local backups
#   test    <server|all>   Test SSH connection(s)
#   --create-config        Generate default configuration files
#   --help                 Show this help message
#   --version              Show version
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Script metadata
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="mailcow-backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# ---------------------------------------------------------------------------
# Log file location (must be set before sourcing logging.sh)
# ---------------------------------------------------------------------------
export LOG_FILE="${SCRIPT_DIR}/logs/backup.log"

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
# shellcheck source=lib/colors.sh
source "${SCRIPT_DIR}/lib/colors.sh"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"

# ---------------------------------------------------------------------------
# show_help
# ---------------------------------------------------------------------------
show_help() {
    cat << EOF
${BOLD_CYAN}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}
Backup agent for Mailcow Dockerized installations.

${BOLD_WHITE}USAGE${RESET}
  ./mailcow-backup.sh <command> [server|all] [options]

${BOLD_WHITE}COMMANDS${RESET}
  ${BOLD_GREEN}backup${RESET}  <server|all>   SSH into server(s), run mailcow backup, download result
  ${BOLD_GREEN}list${RESET}    <server|all>   List stored local backups
  ${BOLD_GREEN}cleanup${RESET} <server|all>   Apply retention policy (remove old backups)
  ${BOLD_GREEN}test${RESET}    <server|all>   Test SSH connectivity

${BOLD_WHITE}OPTIONS${RESET}
  --create-config          Generate default config/backup.conf and config/servers.conf
  --help                   Show this help message
  --version                Show version number
  --debug                  Enable debug output (or set DEBUG=1)

${BOLD_WHITE}EXAMPLES${RESET}
  # First-time setup
  ./mailcow-backup.sh --create-config

  # Test all enabled servers
  ./mailcow-backup.sh test all

  # Backup a specific server
  ./mailcow-backup.sh backup production

  # Backup all enabled servers
  ./mailcow-backup.sh backup all

  # List backups
  ./mailcow-backup.sh list production

  # Cleanup (apply retention) for all servers
  ./mailcow-backup.sh cleanup all

${BOLD_WHITE}ENVIRONMENT${RESET}
  DEBUG=1                  Enable debug log output
  NO_COLOR=1               Disable colored output

${BOLD_WHITE}CONFIGURATION${RESET}
  config/backup.conf       Global backup settings
  config/servers.conf      Per-server SSH and mailcow settings

EOF
}

# ---------------------------------------------------------------------------
# cmd_backup <server_identifier>
# ---------------------------------------------------------------------------
cmd_backup() {
    local target="$1"
    load_main_config || exit 1
    mkdir -p "$BACKUP_ROOT"

    local servers=()
    if [ "$target" = "all" ]; then
        mapfile -t servers < <(list_enabled_servers)
        if [ ${#servers[@]} -eq 0 ]; then
            log_error "No enabled servers found in servers.conf."
            exit 1
        fi
    else
        servers=("$target")
    fi

    local overall_exit=0

    for server in "${servers[@]}"; do
        load_server_config "$server" || { overall_exit=1; continue; }
        validate_server_config      || { overall_exit=1; continue; }

        if ! backup_server; then
            log_error "Backup failed for '$server'."
            overall_exit=1
        fi

        # Apply local retention after every successful backup
        cleanup_server "$server" "$SERVER_RETENTION_COUNT"
    done

    return $overall_exit
}

# ---------------------------------------------------------------------------
# cmd_list <server_identifier>
# ---------------------------------------------------------------------------
cmd_list() {
    local target="$1"
    load_main_config || exit 1

    local servers=()
    if [ "$target" = "all" ]; then
        mapfile -t servers < <(list_servers)
    else
        servers=("$target")
    fi

    for server in "${servers[@]}"; do
        list_backups_for_server "$server"
    done
}

# ---------------------------------------------------------------------------
# cmd_cleanup <server_identifier>
# ---------------------------------------------------------------------------
cmd_cleanup() {
    local target="$1"
    load_main_config || exit 1

    local servers=()
    if [ "$target" = "all" ]; then
        mapfile -t servers < <(list_servers)
    else
        servers=("$target")
    fi

    for server in "${servers[@]}"; do
        # Load server config to get per-server retention_count (best-effort)
        if load_server_config "$server" 2>/dev/null; then
            cleanup_server "$server" "$SERVER_RETENTION_COUNT"
        else
            cleanup_server "$server"
        fi
    done
}

# ---------------------------------------------------------------------------
# cmd_test <server_identifier>
# ---------------------------------------------------------------------------
cmd_test() {
    local target="$1"
    load_main_config || exit 1

    local servers=()
    if [ "$target" = "all" ]; then
        mapfile -t servers < <(list_enabled_servers)
        if [ ${#servers[@]} -eq 0 ]; then
            log_warn "No enabled servers found in servers.conf."
            exit 0
        fi
    else
        servers=("$target")
    fi

    local overall_exit=0

    for server in "${servers[@]}"; do
        load_server_config "$server" || { overall_exit=1; continue; }
        validate_server_config      || { overall_exit=1; continue; }
        log_section "Testing: $server"
        ssh_test || overall_exit=1
    done

    return $overall_exit
}

# ---------------------------------------------------------------------------
# parse_args / main
# ---------------------------------------------------------------------------
main() {
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    # Parse global flags first
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --debug)   export DEBUG=1 ;;
            --help)    show_help; exit 0 ;;
            --version) echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
            --create-config)
                # Load colors/logging already sourced; config not loaded yet
                create_default_config
                exit $?
                ;;
            *) args+=("$arg") ;;
        esac
    done

    set -- "${args[@]+"${args[@]}"}"

    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    local command="$1"
    local server_arg="${2:-}"

    case "$command" in
        backup)
            [ -z "$server_arg" ] && { log_error "'backup' requires a server name or 'all'."; show_help; exit 1; }
            cmd_backup "$server_arg"
            ;;
        list)
            [ -z "$server_arg" ] && { log_error "'list' requires a server name or 'all'."; show_help; exit 1; }
            cmd_list "$server_arg"
            ;;
        cleanup)
            [ -z "$server_arg" ] && { log_error "'cleanup' requires a server name or 'all'."; show_help; exit 1; }
            cmd_cleanup "$server_arg"
            ;;
        test)
            [ -z "$server_arg" ] && { log_error "'test' requires a server name or 'all'."; show_help; exit 1; }
            cmd_test "$server_arg"
            ;;
        *)
            log_error "Unknown command: '$command'"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
