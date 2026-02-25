#!/bin/bash
# lib/backup.sh - Core backup logic for a single Mailcow server
# Expects SERVER_* variables and global config to be loaded before use.

# ---------------------------------------------------------------------------
# _remote_backup_script_path
#   Returns the full path to the mailcow backup script on the remote server.
# ---------------------------------------------------------------------------
_remote_backup_script_path() {
    echo "${SERVER_MAILCOW_INSTALL_DIR}/helper-scripts/backup_and_restore.sh"
}

# ---------------------------------------------------------------------------
# _build_remote_backup_cmd
#   Constructs the full command to invoke on the remote server to run
#   the mailcow backup_and_restore.sh script.
# ---------------------------------------------------------------------------
_build_remote_backup_cmd() {
    local script
    script="$(_remote_backup_script_path)"
    local components="${SERVER_BACKUP_COMPONENTS}"
    local cmd=""

    # Optional THREADS prefix
    if [ -n "$SERVER_THREADS" ]; then
        cmd="THREADS=${SERVER_THREADS} "
    fi

    # MAILCOW_BACKUP_LOCATION must be set so the script runs unattended
    cmd+="MAILCOW_BACKUP_LOCATION=${SERVER_REMOTE_BACKUP_PATH} "
    cmd+="${script} backup ${components}"

    # Optional --delete-days
    if [ -n "$SERVER_DELETE_DAYS" ]; then
        cmd+=" --delete-days ${SERVER_DELETE_DAYS}"
    fi

    echo "$cmd"
}

# ---------------------------------------------------------------------------
# backup_preflight_checks
#   Verifies the remote server is reachable and the mailcow script exists.
#   Returns 1 if any check fails.
# ---------------------------------------------------------------------------
backup_preflight_checks() {
    log_step "Running pre-flight checks..."

    # SSH connectivity
    ssh_test || return 1

    # mailcow backup script present
    local script
    script="$(_remote_backup_script_path)"
    ssh_check_file "$script" || {
        log_error "Mailcow backup script not found at ${script}"
        log_error "Verify 'mailcow_install_dir' in servers.conf (currently: ${SERVER_MAILCOW_INSTALL_DIR})"
        return 1
    }

    # rsync available on remote
    ssh_check_command "rsync" || return 1

    # Ensure remote backup target directory exists
    log_step "Ensuring remote backup path exists: ${SERVER_REMOTE_BACKUP_PATH}"
    ssh_run "mkdir -p '${SERVER_REMOTE_BACKUP_PATH}'" || {
        log_error "Cannot create remote backup path: ${SERVER_REMOTE_BACKUP_PATH}"
        return 1
    }

    log_success "Pre-flight checks passed."
    return 0
}

# ---------------------------------------------------------------------------
# backup_run_remote
#   Executes the mailcow backup script on the remote server.
#   Returns 1 on failure.
# ---------------------------------------------------------------------------
backup_run_remote() {
    local cmd
    cmd="$(_build_remote_backup_cmd)"

    log_step "Running mailcow backup on ${SERVER_SSH_HOST}..."
    log_debug "Remote command: $cmd"

    # Run with a pseudo-TTY (-t) so the script output is streamed live
    local ssh_opts
    ssh_opts="$(_ssh_base_opts)"
    local prefix
    prefix="$(_ssh_prefix)"

    # shellcheck disable=SC2086
    eval "${prefix} ssh -t ${ssh_opts} ${SERVER_SSH_USER}@${SERVER_SSH_HOST} \"${cmd}\""
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Remote mailcow backup failed (exit code: $exit_code)"
        return 1
    fi

    log_success "Remote backup completed successfully."
    return 0
}

# ---------------------------------------------------------------------------
# backup_find_latest_remote_dir
#   Finds the most recently created mailcow_DATE directory under
#   SERVER_REMOTE_BACKUP_PATH and sets REMOTE_LATEST_DIR.
# ---------------------------------------------------------------------------
backup_find_latest_remote_dir() {
    log_step "Locating latest backup directory on remote..."

    ssh_run_with_output \
        "ls -1dt '${SERVER_REMOTE_BACKUP_PATH}'/mailcow-* 2>/dev/null | head -1" || {
        log_error "Failed to list remote backup directories."
        return 1
    }

    REMOTE_LATEST_DIR="${SSH_OUTPUT}"
    if [ -z "$REMOTE_LATEST_DIR" ]; then
        log_error "No mailcow_* backup directories found under ${SERVER_REMOTE_BACKUP_PATH}"
        return 1
    fi

    log_debug "Latest remote backup dir: $REMOTE_LATEST_DIR"
    return 0
}

# ---------------------------------------------------------------------------
# backup_download <local_destination_dir>
#   Downloads the latest remote backup directory to <local_destination_dir>
#   using rsync.
# ---------------------------------------------------------------------------
backup_download() {
    local local_dest="$1"

    backup_find_latest_remote_dir || return 1

    log_step "Downloading backup from ${SERVER_SSH_HOST}:${REMOTE_LATEST_DIR} ..."
    log_step "Destination: ${local_dest}"

    rsync_download "$REMOTE_LATEST_DIR" "$local_dest" || {
        log_error "rsync download failed."
        return 1
    }

    log_success "Backup downloaded to ${local_dest}"
    return 0
}

# ---------------------------------------------------------------------------
# backup_cleanup_remote
#   Removes all mailcow_* directories from the remote backup path after a
#   successful download (keeps the remote clean).
# ---------------------------------------------------------------------------
backup_cleanup_remote() {
    log_step "Cleaning up remote backup directories..."

    ssh_run "rm -rf '${SERVER_REMOTE_BACKUP_PATH}'/mailcow-*" || {
        log_warn "Could not clean up remote backup path: ${SERVER_REMOTE_BACKUP_PATH}"
        return 0   # non-fatal
    }

    log_success "Remote backup staging area cleaned."
}

# ---------------------------------------------------------------------------
# write_backup_metadata <backup_dir>
#   Writes a backup_info.txt into the local backup directory.
# ---------------------------------------------------------------------------
write_backup_metadata() {
    local backup_dir="$1"
    local info_file="${backup_dir}/backup_info.txt"

    cat > "$info_file" << EOF
# Mailcow Backup Metadata
server=${SERVER_NAME}
ssh_host=${SERVER_SSH_HOST}
components=${SERVER_BACKUP_COMPONENTS}
backup_date=$(date '+%Y-%m-%d %H:%M:%S')
remote_source=${SERVER_SSH_HOST}:${REMOTE_LATEST_DIR:-unknown}
local_destination=${backup_dir}
EOF
    log_debug "Backup metadata written to ${info_file}"
}

# ---------------------------------------------------------------------------
# backup_server
#   High-level function: runs the full backup workflow for the currently
#   loaded server.  Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
backup_server() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
    local local_backup_dir="${BACKUP_ROOT}/${SERVER_NAME}/${timestamp}"

    log_section "Backing up: ${SERVER_NAME} (${SERVER_SSH_HOST})"

    # 1. Pre-flight
    backup_preflight_checks || return 1

    # 2. Run mailcow backup script on remote
    backup_run_remote || return 1

    # 3. Download result
    backup_download "$local_backup_dir" || return 1

    # 4. Write metadata
    write_backup_metadata "$local_backup_dir"

    # 5. Clean remote staging area
    backup_cleanup_remote

    log_success "Backup of '${SERVER_NAME}' finished → ${local_backup_dir}"
    return 0
}
