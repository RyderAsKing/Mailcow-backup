#!/bin/bash
# lib/ssh.sh - SSH connection and remote execution utilities
# Expects SERVER_* variables to be set via load_server_config before use.

# ---------------------------------------------------------------------------
# _ssh_base_args
#   Echoes the common SSH options array (no host/user) for reuse.
# ---------------------------------------------------------------------------
_ssh_base_opts() {
    echo -n "-p ${SERVER_SSH_PORT} "
    echo -n "-o ConnectTimeout=${SSH_TIMEOUT} "
    echo -n "-o StrictHostKeyChecking=accept-new "
    echo -n "-o BatchMode=yes "
    if [ "$SERVER_SSH_AUTH_METHOD" = "key" ]; then
        echo -n "-i ${SERVER_SSH_KEY} "
        echo -n "-o PasswordAuthentication=no "
    fi
}

# ---------------------------------------------------------------------------
# _ssh_prefix
#   Echoes "sshpass -p ..." prefix when password auth is used, else empty.
# ---------------------------------------------------------------------------
_ssh_prefix() {
    if [ "$SERVER_SSH_AUTH_METHOD" = "password" ]; then
        echo -n "sshpass -p '${SERVER_SSH_PASS}' "
    fi
}

# ---------------------------------------------------------------------------
# ssh_run <command>
#   Executes <command> on the remote server.
#   Returns the remote exit code.
# ---------------------------------------------------------------------------
ssh_run() {
    local remote_cmd="$1"
    local ssh_opts
    ssh_opts="$(_ssh_base_opts)"
    local prefix
    prefix="$(_ssh_prefix)"

    log_debug "SSH run on ${SERVER_SSH_HOST}: $remote_cmd"

    # shellcheck disable=SC2086
    eval "${prefix} ssh ${ssh_opts} ${SERVER_SSH_USER}@${SERVER_SSH_HOST} \"${remote_cmd}\""
    return $?
}

# ---------------------------------------------------------------------------
# ssh_run_with_output <command>
#   Like ssh_run but captures stdout in SSH_OUTPUT and returns exit code.
# ---------------------------------------------------------------------------
ssh_run_with_output() {
    local remote_cmd="$1"
    local ssh_opts
    ssh_opts="$(_ssh_base_opts)"
    local prefix
    prefix="$(_ssh_prefix)"

    log_debug "SSH run (capture) on ${SERVER_SSH_HOST}: $remote_cmd"

    # shellcheck disable=SC2086
    SSH_OUTPUT="$(eval "${prefix} ssh ${ssh_opts} ${SERVER_SSH_USER}@${SERVER_SSH_HOST} \"${remote_cmd}\"")"
    return $?
}

# ---------------------------------------------------------------------------
# ssh_test
#   Tests the SSH connection. Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
ssh_test() {
    log_step "Testing SSH connection to ${SERVER_SSH_USER}@${SERVER_SSH_HOST}:${SERVER_SSH_PORT} ..."

    local ssh_opts
    ssh_opts="$(_ssh_base_opts)"
    local prefix
    prefix="$(_ssh_prefix)"

    # shellcheck disable=SC2086
    if eval "${prefix} ssh ${ssh_opts} ${SERVER_SSH_USER}@${SERVER_SSH_HOST} 'echo __ssh_ok__'" 2>/dev/null | grep -q '__ssh_ok__'; then
        log_success "SSH connection successful."
        return 0
    else
        log_error "Cannot connect to ${SERVER_SSH_HOST}."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# rsync_download <remote_path> <local_path> [extra_rsync_args]
#   Downloads <remote_path> from the server to <local_path> using rsync over SSH.
# ---------------------------------------------------------------------------
rsync_download() {
    local remote_path="$1"
    local local_path="$2"
    shift 2
    local extra_args=("$@")

    local ssh_cmd
    ssh_cmd="ssh $(_ssh_base_opts)"

    local rsync_prefix=""
    if [ "$SERVER_SSH_AUTH_METHOD" = "password" ]; then
        rsync_prefix="sshpass -p ${SERVER_SSH_PASS} "
    fi

    mkdir -p "$local_path"

    log_debug "rsync from ${SERVER_SSH_HOST}:${remote_path} → ${local_path}"

    # shellcheck disable=SC2086
    eval "${rsync_prefix} rsync -aH --info=progress2 --delete \
        -e \"${ssh_cmd}\" \
        \"${SERVER_SSH_USER}@${SERVER_SSH_HOST}:${remote_path}/\" \
        \"${local_path}/\" \
        ${extra_args[*]+"${extra_args[@]}"}"
    return $?
}

# ---------------------------------------------------------------------------
# ssh_check_command <command_name>
#   Checks that <command_name> exists on the remote server.
# ---------------------------------------------------------------------------
ssh_check_command() {
    local cmd="$1"
    if ssh_run "command -v ${cmd} >/dev/null 2>&1"; then
        log_debug "Remote command '${cmd}' is available."
        return 0
    else
        log_error "Remote command '${cmd}' not found on ${SERVER_SSH_HOST}."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# ssh_check_file <path>
#   Checks that a file or directory exists on the remote server.
# ---------------------------------------------------------------------------
ssh_check_file() {
    local path="$1"
    if ssh_run "[ -e \"${path}\" ]"; then
        return 0
    else
        log_error "Remote path not found: ${path}"
        return 1
    fi
}
