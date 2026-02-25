#!/bin/bash
# lib/cleanup.sh - Local backup retention management

# ---------------------------------------------------------------------------
# list_local_backups <server_name>
#   Lists local backup timestamp directories for <server_name>, oldest first.
# ---------------------------------------------------------------------------
list_local_backups() {
    local server="$1"
    local server_dir="${BACKUP_ROOT}/${server}"

    if [ ! -d "$server_dir" ]; then
        return 0
    fi

    find "$server_dir" -mindepth 1 -maxdepth 1 -type d \
        | sort   # ascending = oldest first
}

# ---------------------------------------------------------------------------
# count_local_backups <server_name>
# ---------------------------------------------------------------------------
count_local_backups() {
    local server="$1"
    list_local_backups "$server" | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# cleanup_server <server_name> [retention_count]
#   Removes old local backups for <server_name>, keeping the newest
#   <retention_count> copies. Uses SERVER_RETENTION_COUNT if not passed.
# ---------------------------------------------------------------------------
cleanup_server() {
    local server="$1"
    local keep="${2:-${SERVER_RETENTION_COUNT:-7}}"
    local server_dir="${BACKUP_ROOT}/${server}"

    if [ ! -d "$server_dir" ]; then
        log_debug "No local backup directory for '$server' – nothing to clean."
        return 0
    fi

    local all_backups
    mapfile -t all_backups < <(list_local_backups "$server")
    local total=${#all_backups[@]}

    if [ "$total" -le "$keep" ]; then
        log_info "[$server] $total backup(s) found, retention=$keep – nothing to remove."
        return 0
    fi

    local to_delete=$(( total - keep ))
    log_step "[$server] $total backup(s) found, keeping $keep – removing $to_delete oldest..."

    local i=0
    for backup_dir in "${all_backups[@]}"; do
        if [ "$i" -ge "$to_delete" ]; then
            break
        fi
        log_step "  Removing: $backup_dir"
        rm -rf "$backup_dir" && log_debug "Removed $backup_dir" || log_warn "Failed to remove $backup_dir"
        (( i++ )) || true
    done

    log_success "[$server] Cleanup complete. Kept $keep most recent backup(s)."
}

# ---------------------------------------------------------------------------
# list_backups_for_server <server_name>
#   Prints a formatted table of local backups for the given server.
# ---------------------------------------------------------------------------
list_backups_for_server() {
    local server="$1"
    local server_dir="${BACKUP_ROOT}/${server}"

    log_section "Backups for: $server"

    if [ ! -d "$server_dir" ]; then
        log_warn "No backups found for '$server'."
        return 0
    fi

    local backups
    mapfile -t backups < <(list_local_backups "$server" | sort -r)  # newest first

    if [ ${#backups[@]} -eq 0 ]; then
        log_warn "No backups found for '$server'."
        return 0
    fi

    printf "  %-30s  %-12s\n" "TIMESTAMP" "SIZE"
    printf "  %-30s  %-12s\n" "------------------------------" "------------"

    for backup_dir in "${backups[@]}"; do
        local dir_name size
        dir_name="$(basename "$backup_dir")"
        size="$(du -sh "$backup_dir" 2>/dev/null | cut -f1)"
        printf "  %-30s  %-12s\n" "$dir_name" "$size"
    done

    echo ""
    log_info "Total: ${#backups[@]} backup(s) for '$server'"
}
