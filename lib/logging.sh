#!/bin/bash
# lib/logging.sh - Logging utilities
# Requires: lib/colors.sh to be sourced first

# Log file is set by main script; default fallback
LOG_FILE="${LOG_FILE:-./logs/backup.log}"

# Ensure log directory exists
_ensure_log_dir() {
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    mkdir -p "$log_dir"
}

# Internal: write raw message to log file
_log_to_file() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    _ensure_log_dir
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# log_info: informational message
log_info() {
    local message="$1"
    echo -e "${BLUE}[INFO]${RESET}  $message"
    _log_to_file "INFO" "$message"
}

# log_success: success message
log_success() {
    local message="$1"
    echo -e "${BOLD_GREEN}[OK]${RESET}    $message"
    _log_to_file "OK" "$message"
}

# log_warn: warning message
log_warn() {
    local message="$1"
    echo -e "${YELLOW}[WARN]${RESET}  $message"
    _log_to_file "WARN" "$message"
}

# log_error: error message (also writes to stderr)
log_error() {
    local message="$1"
    echo -e "${BOLD_RED}[ERROR]${RESET} $message" >&2
    _log_to_file "ERROR" "$message"
}

# log_section: visual section header
log_section() {
    local title="$1"
    local line="──────────────────────────────────────────────"
    echo -e "\n${BOLD_CYAN}${line}${RESET}"
    echo -e "${BOLD_CYAN}  $title${RESET}"
    echo -e "${BOLD_CYAN}${line}${RESET}"
    _log_to_file "----" "=== $title ==="
}

# log_step: sub-step message
log_step() {
    local message="$1"
    echo -e "${MAGENTA}  »${RESET} $message"
    _log_to_file "STEP" "$message"
}

# log_debug: only shown when DEBUG=1
log_debug() {
    local message="$1"
    if [ "${DEBUG:-0}" = "1" ]; then
        echo -e "${WHITE}[DEBUG]${RESET} $message"
    fi
    _log_to_file "DEBUG" "$message"
}
