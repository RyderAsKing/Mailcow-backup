#!/bin/bash
# lib/colors.sh - Terminal color definitions

# Reset
RESET='\033[0m'

# Regular colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

# Bold colors
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
BOLD_BLUE='\033[1;34m'
BOLD_MAGENTA='\033[1;35m'
BOLD_CYAN='\033[1;36m'
BOLD_WHITE='\033[1;37m'

# Check if terminal supports color
if [ ! -t 1 ] || [ "${NO_COLOR:-}" = "1" ]; then
    RESET=''
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE=''
    BOLD_RED='' BOLD_GREEN='' BOLD_YELLOW='' BOLD_BLUE=''
    BOLD_MAGENTA='' BOLD_CYAN='' BOLD_WHITE=''
fi
