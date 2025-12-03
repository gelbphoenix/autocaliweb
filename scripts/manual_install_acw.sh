#!/bin/bash
# manual_install_acw.sh - Run this as root
# V.3.7.4
# Copyright (C) 2025 Autocaliweb
# First creator UsamaFoad <usamafoad@gmail.com>
#
# If you work in this file kindly make sure to check it with shellcheck
# the following options: shellcheck -x --extended-analysis=true
# and apply all the recommendations.
# For more information see: https://www.shellcheck.net/wiki/
#
# Also, it will be great if you check the script format with shfmt -i 4 -ci

set -e
set -o pipefail

DEBUG_MODE="${DEBUG_MODE:-0}"

# Define ANSI color/style codes (only for TTY)
BOLD=$'\033[1m'
RED=$'\033[31m'
GREEN=$'\033[32m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
PURPLE=$'\033[35m'
YELLOW=$'\033[1;33m'
RESET=$'\033[0m'

# Raw version number (for logs, automation, comparisons)
VERSION_NUMBER="3.7.4"

# Pretty version banner (for --version output)
VERSION=$(
    cat <<EOF
${BOLD}${BLUE}Autocaliweb Manual Install ${VERSION_NUMBER}${RESET}

Copyright (C) 2025 Autocaliweb.
${GREEN}https://github.com/gelbphoenix/autocaliweb${RESET}

License GPL-3.0: GNU GPL version 3 or later <${GREEN}https://gnu.org/licenses/gpl.html${RESET}>.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

${BOLD}Autocaliweb${RESET}
Created by ${YELLOW}Phoenix Paulina Schmid${RESET}.
Manual install by ${YELLOW}UsamaFoad${RESET}.
EOF
)

# Global variables for OS detection (distro)
ID=""
VERSION_ID=""

VERBOSE="${VERBOSE:-0}"
UNINSTALL_MODE="${UNINSTALL_MODE:-0}"
ACCEPT_ALL="${ACCEPT_ALL:-0}"
DISTRO_CHECK_ONLY="${DISTRO_CHECK_ONLY:-0}"
SKIP_UPDATE="${SKIP_UPDATE:-0}" # New: Flag to skip package manager update
UPDATE_RAN=0                    # New: Track if the package update has already run
unset IS_HEADLESS               # Default: unset so we know if user forced it
ALLOW_LOW_SPACE=0

# CONFIGURATION
INSTALL_DIR_DEFAULT="/opt/autocaliweb"
CONFIG_DIR_DEFAULT="${INSTALL_DIR_DEFAULT}/config"
LOG_FILE_DEFAULT="/tmp/manual_install_acw.log"

CALIBRE_LIB_DIR_DEFAULT="/srv/calibre-library"
INGEST_DIR_DEFAULT="/srv/acw-book-ingest"
INGEST_DIR="${INGEST_DIR:-$INGEST_DIR_DEFAULT}"

LOG_FILE="${ACW_LOG_FILE:-$LOG_FILE_DEFAULT}" # not documented but available ACW_LOG_FILE
INSTALL_DIR="${ACW_INSTALL_DIR:-$INSTALL_DIR_DEFAULT}"
CONFIG_DIR="${ACW_CONFIG_DIR:-$CONFIG_DIR_DEFAULT}"

# Derived paths for clarity and reuse
# Based on CONFIG_DIR
PROCESSED_BOOKS_BASE="${CONFIG_DIR}/processed_books"
CALIBRE_PLUGIN_DIR="${CONFIG_DIR}/.config/calibre/plugins"
LOG_ARCHIVE_DIR="${CONFIG_DIR}/log_archive"
CONVERSION_TMP_DIR="${CONFIG_DIR}/.acw_conversion_tmp"

# Based on INSTALL_DIR
METADATA_CHANGE_LOGS_DIR="${INSTALL_DIR}/metadata_change_logs"
METADATA_TEMP_DIR="${INSTALL_DIR}/metadata_temp"

# Get the actual user who called sudo
REAL_USER=${SUDO_USER:-$USER}
REAL_GROUP=$(id -gn "$REAL_USER")
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

USER_HOME="$(eval echo "~$REAL_USER")"

LEGACY_INSTALL_DIR="/app/autocaliweb"
LEGACY_CONFIG_DIR="/config"
LEGACY_CALIBRE_LIB_DIR="/calibre-library"
LEGACY_SERVICE_USER="abc"
LEGACY_SERVICE_GROUP="abc"

SERVICE_USER="${ACW_USER:-$LEGACY_SERVICE_USER}"
SERVICE_GROUP="${ACW_GROUP:-$LEGACY_SERVICE_GROUP}"

GIT_CHECK_USER=""

EXISTING_INSTALLATION=false

PYTHON_VERSION="0"

# Global flags to track installation state
IS_LEGACY_MIGRATION=false
IS_UPDATE=false
SCRIPT_SOURCE_DIR=""
IS_UPDATE=false
SCENARIO=""
UNRAR_PATH=""
FIX_PYTHON_PAC=false

readonly CALIBRE_ARCHIVE_MB=200 # Temporary space for the Calibre download
readonly CALIBRE_INSTALL_MB=600 # Final installed size of Calibre
readonly ACW_INSTALL_MB=500     # Installed size of Autocaliweb (including venv)
readonly SYS_PKG_INSTALL_MB=800 # Net space used by required system packages (from DNF output)
readonly BUFFER_MB=200          # Safety buffer for temporary files/filesystem overhead
declare -i TOTAL_SPACE_REQUIRED # Calculate required space based on what already exists.

show_version() {
    echo "$VERSION"
}

# Strip ANSI codes helper
_strip_ansi() {
    sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

_trim() {
    local var="$1"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]*}"}"
    echo -n "$var"
}

_pad_to_length() {
    local word="$1"
    local target_length="$2"
    printf "%-*s" "$target_length" "$word"
}

_log_message() {
    local level="$1"          # INFO / WARNING / ERROR / DEBUG / PROMPT / ANSWER
    local color="$2"          # ${GREEN}, ${YELLOW}, ${RED}, ${CYAN}, ${PURPLE}
    local msg="$3"            # Message text
    local additional_log="$4" # Optional extra log file
    local stream="$5"         # 1=stdout, 2=stderr
    local REQUIRED_LENGTH=7   # max length of: INFO / WARNING / ERROR / DEBUG / PROMPT / ANSWER

    # Skip VERBOSE messages if both VERBOSE and DEBUG_MODE are off
    if [[ "$level" == "VERBOSE" && "$VERBOSE" -ne 1 && "$DEBUG_MODE" -ne 1 ]]; then
        return
    fi
    # Skip DEBUG messages if DEBUG_MODE is off
    if [[ "$level" == " DEBUG " && "$DEBUG_MODE" -ne 1 ]]; then
        return
    fi
    # Print to console (with color). Exclude: PROMPT & ANSWER, handled by print_prompt
    if [[ "$level" != "PROMPT " && "$level" != "ANSWER " && "$level" != "option " ]]; then
        echo -e "${color}[${level}]${RESET} $msg" >&"$stream"
    elif [[ "$level" == "option " ]]; then
        local menu_padding
        menu_padding=$(_pad_to_length "" "9") # REQUIRED_LENGTH + 2
        echo -e "${menu_padding} $msg" >&"$stream"
    fi

    # Prepare log-safe message (strip ANSI codes)
    local clean_msg
    local clean_level
    local final_level
    # Use printf for reliable stripping of non-printing characters
    clean_msg=$(printf '%s' "$msg" | _strip_ansi)
    # Prepare levels for log file (left-align & pad as the largest level length)
    clean_level=$(_trim "$level")
    final_level=$(_pad_to_length "$clean_level" "$REQUIRED_LENGTH")

    # Log to main log file (if set)
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$(date)] $final_level: $clean_msg" >>"$LOG_FILE" 2>/dev/null || true
    fi

    # Log to additional log (if provided)
    if [[ -n "$additional_log" ]]; then
        echo "[$(date)] $final_level: $clean_msg" >>"$additional_log" 2>/dev/null || true
    fi
}

print_status() {
    _log_message " INFO  " "$GREEN" "$1" "$2" 1
}

print_warning() {
    _log_message "WARNING" "$YELLOW" "$1" "$2" 1
}

print_error() {
    _log_message " ERROR " "$RED" "$1" "$2" 2
}

print_verbose() {
    _log_message "VERBOSE" "$BLUE" "$1" "$2" 1
}

print_debug() {
    _log_message " DEBUG " "$CYAN" "$1" "$2" 1
}

print_option() {
    _log_message "option " "$RESET" "$1" "$2" 1 "$3"
}

print_prompt() {
    local question="$1"
    local variable_name="$2" # return the input into it.
    local single_char="$3"   # Set to 'true' for instant read, otherwise standard read

    _log_message "PROMPT " "$PURPLE" "$question" "" 1

    echo -n -e "${PURPLE}[PROMPT ]${RESET} $question: " >&1
    if [[ "$single_char" == "true" ]]; then
        read -r -n 1 "${variable_name?}"
        echo "" # Add newline after instant read
    else
        # Standard read (requires Enter)
        read -r "${variable_name?}"
    fi

    _log_message "ANSWER " "$PURPLE" "${!variable_name}" "" 1
}

# Ordered list of all option keys
declare -a ALL_OPTIONS=(
    "-i"  # --install-dir
    "-c"  # --config-dir
    "-l"  # --library-dir
    "-g"  # --ingest-dir
    "-u"  # --acw-user
    "-G"  # --acw-group
    "-o"  # --log
    "-y"  # --yes
    "-v"  # --verbose
    "-d"  # --debug
    "-U"  # --uninstall
    "-H"  # --headless
    "-D"  # --desktop
    "-V"  # --version
    "-dc" # --distro-check-only
    "-su" # --skip-update
    "-a"  # --allow-low-space
    # "-h"       # --help # Avoid infinity loop
    "-H_Detection" # Headless/desktop detection (not argument just help section)
    "env"          # The environment variable section
)

# Helper function to print the details for a key
print_option_details() {
    case "$1" in
        -i | --install-dir)
            cat <<EOF
${BOLD}-i, --install-dir <DIR>${RESET} Specify the installation directory for Autocaliweb.
                        Defaults to '${YELLOW}$INSTALL_DIR_DEFAULT${RESET}' if not specified.
                        Examples:
                            ${GREEN}-i /usr/local/autocaliweb${RESET}
                            ${GREEN}--install-dir "/home/youruser/apps/autocaliweb"${RESET}

EOF
            ;;
        -c | --config-dir)
            cat <<EOF
${BOLD}-c, --config-dir <DIR>${RESET}  Specify the configuration directory
                        Defaults to '${YELLOW}$CONFIG_DIR_DEFAULT${RESET}'.
                        Examples:
                            ${GREEN}-c /etc/autocaliweb/config${RESET}
                            ${GREEN}--config-dir "/var/lib/autocaliweb/config"${RESET}

EOF
            ;;
        -l | --library-dir)
            cat <<EOF
${BOLD}-l, --library-dir <DIR>${RESET} Specify the Calibre library root directory.
                        Defaults to '${YELLOW}$CALIBRE_LIB_DIR_DEFAULT${RESET}'.
                        Examples:
                           ${GREEN}-l /mnt/storage/CalibreLibrary${RESET}
                           ${GREEN}--library-dir "/home/youruser/My Books/Calibre"${RESET}

EOF
            ;;
        -g | --ingest-dir)
            cat <<EOF
${BOLD}-g, --ingest-dir <DIR>${RESET}  Directory for new books to be processed.
                        Defaults to '${YELLOW}$INGEST_DIR_DEFAULT${RESET}'.
                        Examples:
                           ${GREEN}-g /mnt/storage/NewBooks${RESET}
                           ${GREEN}--ingest-dir "/home/youruser/Downloads/to_ingest"${RESET}

EOF
            ;;
        -u | --acw-user)
            cat <<EOF
${BOLD}-u, --acw-user <USER>${RESET}   User account for Autocaliweb services.
                        Defaults to '${YELLOW}$LEGACY_SERVICE_USER${RESET}'.
                        Example:
                           ${GREEN}--acw-user "autocali" ${RESET}

EOF
            ;;
        -G | --acw-group)
            cat <<EOF
-G, --acw-group <GROUP> Primary group for Autocaliweb services.
                        Will be assigned ownership of installed files and directories.
                        Defaults to '${YELLOW}$LEGACY_SERVICE_GROUP${RESET}'.
                        Example:
                             ${GREEN}-G "acwusers" ${RESET}

EOF
            ;;
        -o | --log)
            cat <<EOF
${BOLD}-o, --log <PATH>${RESET}        Path to installation log file.
                        Defaults to '${YELLOW}$LOG_FILE_DEFAULT${RESET}'.
                        Use ${CYAN}""${RESET} to disable logging.
                        ${BOLD}Migration log${RESET}, if applicable, uses the same folder as the log or
                        defaults to '${YELLOW}/tmp/acw_migration_(date + time).log${RESET}'

EOF
            ;;
        -y | --yes | --Yes)
            cat <<EOF
${BOLD}-y, --yes${RESET}               Accept all prompts automatically
                        (non-interactive install only).
                        Does not apply to '--uninstall' mode, which requires explicit confirmation.

EOF
            ;;
        -v | --verbose)
            cat <<EOF
${BOLD}-v, --verbose${RESET}           Enable verbose output.

EOF
            ;;
        -d | --debug)
            cat <<EOF
${BOLD}-d, --debug${RESET}             Enable debug mode.

EOF
            ;;
        -U | --uninstall)
            cat <<EOF
${BOLD}-U, --uninstall${RESET}         Run the uninstaller.

EOF
            ;;
        -V | --version)
            cat <<EOF
${BOLD}-V, --version${RESET}           Show script version and exit.

EOF
            ;;
        -dc | --distro-check-only)
            cat <<EOF
${BOLD}-dc, --distro-check-only${RESET} Check if your distro is supported before attempting install and exit.

EOF
            ;;
        -su | --skip-update)
            cat <<EOF
${BOLD}-su, --skip-update${RESET}        Skip package manager update.

EOF
            ;;
        -H | --headless)
            cat <<EOF
${BOLD}-H, --headless${RESET}          Force headless mode, installing only minimal runtime graphics
                        dependencies (useful for servers without a GUI/X11).

EOF
            ;;
        -D | --desktop)
            cat <<EOF
${BOLD}-D, --desktop${RESET}           Force desktop mode, installing the full graphics/X11 stack.
                        (By default, mode is auto-detected based on DISPLAY/WAYLAND_DISPLAY).

EOF
            ;;
        -H_Detection)
            cat <<EOF
${BOLD}Headless/desktop detection:${RESET}
    If neither --headless nor --desktop are provided:
      • If no GUI environment is detected (${YELLOW}DISPLAY${RESET} and ${YELLOW}WAYLAND_DISPLAY${RESET} unset),
        the script defaults to ${GREEN}headless mode${RESET}.
      • Otherwise, it defaults to ${GREEN}desktop mode${RESET}.

EOF
            ;;
        -a | --allow-low-space)
            cat <<EOF
${BOLD}-a, --allow-low-space${RESET}     Bypass the minimum disk space check and proceed with a warning.

EOF
            ;;
        env | environment)
            cat <<EOF
${BOLD}Environment Variables:${RESET}
    ${YELLOW}ACW_INSTALL_DIR${RESET}   Overrides '--install-dir' default.
    ${YELLOW}ACW_CONFIG_DIR${RESET}    Overrides '--config-dir' default.
    ${YELLOW}LIBRARY_DIR${RESET}       Compatibility: overrides '--library-dir' default (used by Docker).
    ${YELLOW}INGEST_DIR${RESET}        Compatibility: overrides '--ingest-dir' default.
    ${YELLOW}ACW_USER${RESET}          Overrides '--acw-user' default.
    ${YELLOW}ACW_GROUP${RESET}         Overrides '--acw-group' default.

To set an environment variable, ${BOLD}export it before running the script${RESET}:

Examples:
    ${GREEN}export ACW_INSTALL_DIR="/usr/local/autocaliweb"${RESET}
    ${GREEN}export ACW_CONFIG_DIR="/opt/autocaliweb/config-data"${RESET}
    ${GREEN}export ACW_USER="autocali"${RESET}
    ${GREEN}export ACW_GROUP="acwusers"${RESET}
    ${GREEN}export LIBRARY_DIR="/mnt/books/Calibre Library"${RESET}
    ${GREEN}export INGEST_DIR="/mnt/storage/New Books"${RESET}

The manual install will utilize these variables, and if the corresponding command-line
options aren't provided, it will make these environment variables permanent by adding
them to the system-wide environment (e.g., in '${YELLOW}/etc/environment${RESET}' or '${YELLOW}/etc/autocaliweb/environment${RESET}').
EOF
            ;;
        "")
            cat <<EOF
${BOLD}${BLUE}Autocaliweb Manual Installation Script (v${VERSION_NUMBER}) Help${RESET}

${BOLD}Usage:${RESET} ${CYAN}$0 [OPTIONS]${RESET}

${BOLD}Options:${RESET}
EOF
            # Loop through the global list and print each option's details
            for key in "${ALL_OPTIONS[@]}"; do
                print_option_details "$key" "true"
            done
            echo ""
            echo "$VERSION"
            ;;
        *)
            print_error "Help requested for unknown option: $1"
            local old_IFS="$IFS"
            IFS=", "
            local key_list="${ALL_OPTIONS[*]}"
            IFS="$old_IFS"
            print_option "Please specify a valid option (${key_list})"
            print_option "Try '--help' for the full list of options."
            exit 1
            ;;
    esac
}

# New function signature to accept an optional argument (e.g., '-i' or '--install-dir')
show_help() {
    LOG_FILE="" # Disable loging
    local option_key="$1"

    # Execute the core logic
    if [[ -z "$option_key" ]]; then
        # Print the full help message (the default case)
        print_option_details
    else
        # Print only the requested option's details
        print_option_details "$option_key"
        if [[ "$option_key" == "-H" ]] || [[ "$option_key" == "--headless" ]] ||
            [[ "$option_key" == "-D" ]] || [[ "$option_key" == "--desktop" ]]; then
            print_option_details "-H_Detection"
        fi
    fi
}

require_arg() {
    if [[ -z "$2" || "$2" == --* || "$2" == -* ]]; then
        if [ ! "$1" = "-o" ] && [ ! "$1" = "--log" ]; then # log should accept empty variable
            print_error "Option $1 requires an argument." >&2
            exit 1
        fi
    fi
}

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -i | --install-dir)
                require_arg "$1" "$2"
                # Clean the input by removing a trailing slash if exists.
                INSTALL_DIR="${2%/}"
                shift 2
                ;;
            -c | --config-dir)
                require_arg "$1" "$2"
                CONFIG_DIR="${2%/}"
                shift 2
                ;;
            -l | --library-dir)
                require_arg "$1" "$2"
                CALIBRE_LIB_DIR="${2%/}"
                shift 2
                ;;
            -g | --ingest-dir)
                require_arg "$1" "$2"
                INGEST_DIR="${2%/}"
                shift 2
                ;;
            -u | --acw-user)
                require_arg "$1" "$2"
                ACW_USER="$2"
                shift 2
                ;;
            -G | --acw-group)
                require_arg "$1" "$2"
                ACW_GROUP="$2"
                shift 2
                ;;
            -o | --log)
                require_arg "$1" "$2"
                LOG_FILE="$2"
                shift 2
                ;;
            -y | --yes | --Yes)
                ACCEPT_ALL=1
                shift
                ;;
            -v | --verbose)
                VERBOSE=1
                shift
                ;;
            -d | --debug)
                DEBUG_MODE=1
                shift
                ;;
            -U | --uninstall)
                UNINSTALL_MODE=1
                shift
                ;;
            -V | --version)
                show_version
                exit 0
                ;;
            -dc | --distro-check-only)
                DISTRO_CHECK_ONLY=1
                shift
                ;;
            -su | --skip-update) # New: Flag to skip package manager update
                SKIP_UPDATE=1
                shift
                ;;
            -H | --headless)
                IS_HEADLESS=1
                shift
                ;;
            -D | --desktop)
                IS_HEADLESS=0
                shift
                ;;
            -a | --allow-low-space)
                ALLOW_LOW_SPACE=1
                shift
                ;;
            -h | --help)
                if [[ -n "$2" ]] && { [[ "$2" == -* ]] ||
                    [[ "$2" == "env" ]] || [[ "$2" == "environment" ]]; }; then
                    show_help "$2" # help for a specific option (e.g., -h -i)
                else
                    show_help # generic help
                fi
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                print_status "Use --help to see available options."
                exit 1
                ;;
        esac
    done

    INSTALL_DIR="${INSTALL_DIR:-$INSTALL_DIR_DEFAULT}"
    CONFIG_DIR="${CONFIG_DIR:-$CONFIG_DIR_DEFAULT}"
    CALIBRE_LIB_DIR="${LIBRARY_DIR:-$CALIBRE_LIB_DIR_DEFAULT}"
    INGEST_DIR="${INGEST_DIR:-$INGEST_DIR_DEFAULT}"
    LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"
}

# Detect headless mode unless overridden
detect_headless_mode() {
    local gui_found=0
    local display_vars_set=0

    # Check if DISPLAY or WAYLAND_DISPLAY are explicitly set (fastest check)
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
        gui_found=1
        display_vars_set=1
    fi

    # If no display variables or not explicitly set, check for common GUI processes/servers
    if [ "$gui_found" -eq 0 ]; then
        # Check for common Display Managers, X Servers, and Wayland Compositors
        # Using pgrep for maximum compatibility across distributions (Debian, Fedora, SUSE, Arch)
        if pgrep -f "gdm|sddm|lightdm|kdm|Xorg|Xwayland|gnome-shell|kwin_wayland" >/dev/null 2>&1; then
            gui_found=1
        fi
    fi

    # Determine IS_HEADLESS status based on flag or auto-detection
    if [ -z "${IS_HEADLESS+x}" ]; then
        # Auto-detection branch
        if [ "$gui_found" -eq 1 ]; then
            IS_HEADLESS=0
            if [ "$display_vars_set" -eq 1 ]; then
                HEADLESS_MODE_SOURCE="(auto-detected: DISPLAY/WAYLAND_DISPLAY set)"
            else
                HEADLESS_MODE_SOURCE="(auto-detected: Display Manager/X Server process running)"
            fi
        else
            IS_HEADLESS=1
            HEADLESS_MODE_SOURCE="(auto-detected: no display environment detected)"
        fi
    else
        # Forced flag branch
        if [ "$IS_HEADLESS" = "1" ]; then
            HEADLESS_MODE_SOURCE="(forced by --headless flag)"
        else
            HEADLESS_MODE_SOURCE="(forced by --desktop flag)"
        fi
    fi

    # Print status
    if [ "$IS_HEADLESS" = "1" ]; then
        print_status "Running in ${BOLD}HEADLESS${RESET} mode $HEADLESS_MODE_SOURCE"
    else
        print_status "Running in ${BOLD}DESKTOP${RESET} mode $HEADLESS_MODE_SOURCE"
    fi
}

set_debug() {
    if [ "$DEBUG_MODE" = "1" ]; then
        print_debug "DEBUG_MODE Activated"
        set -x #DEBUG
    fi
}

is_running_as_root() {
    if [[ $EUID -ne 0 ]]; then
        # We can't use the log file without root permission.
        # Disable log before calling print to avoid: Permission denied error.
        LOG_FILE=""
        print_error "This script must be run as root. Try: (sudo $0 $*)"
        exit 1
    fi
}

set_log_file_permissions() {
    if [ -n "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        # Set the owner to root
        chown root:root "$LOG_FILE"
        # Ensure root has write permissions
        chmod 644 "$LOG_FILE"
    fi
}

# Convert 0/1 flags into human-friendly text
bool_to_status() {
    [[ "$1" -eq 1 ]] && echo "${BOLD}Enabled${RESET}" || echo "Disabled"
}

# Run a long-running command with periodic progress messages
# Arguments:
#   $@: command to run
# Example:
#   run_with_progress sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" install -r requirements.txt
run_with_progress() {
    local start="$SECONDS"
    local cmd=("$@")

    # If command is tar and DEBUG mode is on → make it verbose
    if [[ "${cmd[0]}" == "tar" && "$DEBUG_MODE" -eq 1 ]]; then
        # Append 'v' before the 'f' flag to ensure correct syntax.
        # 'f' must be the last flag in the option string and immediately followed by its argument.
        cmd[1]="${cmd[1]//f/vf}"
    fi
    (
        while true; do
            sleep 60
            local mins=$(((SECONDS - start) / 60))
            print_status "Still running: ${cmd[*]} ... ${mins} minute(s) elapsed."
        done
    ) &
    local progress_pid=$!

    # Ensure cleanup if script exits or is interrupted
    trap 'kill "$progress_pid" 2>/dev/null || true' EXIT INT TERM

    if "${cmd[@]}"; then
        kill "$progress_pid" 2>/dev/null || true
        trap - EXIT INT TERM
        local elapsed=$(((SECONDS - start) / 60))
        print_status "Command '${cmd[*]}' completed successfully in about ${elapsed} minute(s)."
        return 0
    else
        kill "$progress_pid" 2>/dev/null || true
        trap - EXIT INT TERM
        print_error "Command '${cmd[*]}' failed after $(((SECONDS - start) / 60)) minute(s)."
        return 1
    fi
}

# --- Global Package Manager Commands ---
declare -A PKG_INSTALL_ARRAY
declare -A PKG_REMOVE_ARRAY
declare -A PKG_AUTOREMOVE_ARRAY
declare -A PKG_UPDATE_CMD

# --- Debian/Ubuntu ---
PKG_INSTALL_ARRAY["apt-get"]="apt-get install -y --no-install-recommends"
PKG_REMOVE_ARRAY["apt-get"]="apt-get purge -y"
PKG_AUTOREMOVE_ARRAY["apt-get"]="apt-get autoremove -y"
PKG_UPDATE_CMD["apt-get"]="apt-get update"

# --- Fedora ---
PKG_INSTALL_ARRAY[dnf]="dnf install -y"
PKG_REMOVE_ARRAY[dnf]="dnf remove -y"
PKG_AUTOREMOVE_ARRAY[dnf]="dnf autoremove -y"
PKG_UPDATE_CMD[dnf]="dnf makecache"

# --- RHEL / CentOS ---
PKG_INSTALL_ARRAY[yum]="yum install -y"
PKG_REMOVE_ARRAY[yum]="yum remove -y"
PKG_AUTOREMOVE_ARRAY[yum]="yum autoremove -y"
PKG_UPDATE_CMD[yum]="yum makecache"

# --- Arch ---
# The --needed flag prevents re-installing packages that are already up-to-date.
PKG_INSTALL_ARRAY[pacman]="pacman -S --noconfirm --needed"
PKG_REMOVE_ARRAY[pacman]="pacman -Rns --noconfirm"
PKG_AUTOREMOVE_ARRAY[pacman]="pacman -Rns --noconfirm \$(pacman -Qdtq)"
PKG_UPDATE_CMD[pacman]="pacman -Sy"

# --- openSUSE ---
PKG_INSTALL_ARRAY[zypper]="zypper install -y"
PKG_INSTALL_ARRAY[zypper_pattern]="zypper install -y -t"
PKG_REMOVE_ARRAY[zypper]="zypper remove -y"
PKG_AUTOREMOVE_ARRAY[zypper]="zypper remove --clean-deps"
PKG_UPDATE_CMD[zypper]="zypper refresh"

# --- Alpine ---
PKG_INSTALL_ARRAY[apk]="apk add --no-cache"
PKG_REMOVE_ARRAY[apk]="apk del --purge"
PKG_AUTOREMOVE_ARRAY[apk]="apk del --purge \$(apk info -R | grep 'orphaned:yes' | cut -d: -f1)"
PKG_UPDATE_CMD[apk]="apk update"

detect_distro_and_package_manager() {
    local os_release_file=""
    if [[ -f /etc/os-release ]]; then
        os_release_file="/etc/os-release"
    elif [[ -f /usr/lib/os-release ]]; then
        os_release_file="/usr/lib/os-release"
    else
        print_error "Cannot detect Linux distribution: missing os-release"
        return 1
    fi

    # shellcheck source=/dev/null
    . "$os_release_file"

    ID="${ID,,}"
    VERSION_ID="${VERSION_ID:-unknown}"
    PRETTY_NAME="${PRETTY_NAME:-$ID}"
    ID_LIKE="${ID_LIKE:-}"

    case "$ID" in
        debian | ubuntu)
            PKG_MANAGER="apt-get"
            DISTRO_FAMILY="debian"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            DISTRO_FAMILY="fedora"
            ;;
        centos | rhel)
            PKG_MANAGER="yum"
            DISTRO_FAMILY="rhel"
            ;;
        arch)
            PKG_MANAGER="pacman"
            DISTRO_FAMILY="arch"
            ;;
        opensuse-tumbleweed)
            PKG_MANAGER="zypper"
            DISTRO_FAMILY="opensuse-tumbleweed"
            ;;
        opensuse-leap)
            PKG_MANAGER="zypper"
            DISTRO_FAMILY="opensuse-leap"
            ;;
        sles)
            PKG_MANAGER="zypper"
            DISTRO_FAMILY="sles"
            ;;
        *)
            case "$ID_LIKE" in
                *debian* | *ubuntu*)
                    PKG_MANAGER="apt-get"
                    DISTRO_FAMILY="debian"
                    ;;
                *fedora*)
                    PKG_MANAGER="dnf"
                    DISTRO_FAMILY="fedora"
                    ;;
                *centos* | *rhel*)
                    PKG_MANAGER="yum"
                    DISTRO_FAMILY="rhel"
                    ;;
                *arch*)
                    PKG_MANAGER="pacman"
                    DISTRO_FAMILY="arch"
                    ;;
                *opensuse* | *suse* | *sles*)
                    PKG_MANAGER="zypper"
                    # Check if it’s Tumbleweed, Leap, or sles
                    if grep -qi "Tumbleweed" "$os_release_file" 2>/dev/null; then
                        DISTRO_FAMILY="opensuse-tumbleweed"
                    elif grep -qi "Leap" "$os_release_file" 2>/dev/null; then
                        DISTRO_FAMILY="opensuse-leap"
                    else
                        DISTRO_FAMILY="sles"
                    fi
                    ;;
                *)
                    print_error "Unsupported Linux distribution: $ID ($ID_LIKE)"
                    return 1
                    ;;
            esac
            ;;
    esac

    print_status "Detected ${BOLD}$PRETTY_NAME${RESET} ($ID $VERSION_ID). Package manager: ${GREEN}$PKG_MANAGER${RESET}"
    return 0
}

show_distro_support_matrix() {
    cat <<EOF
${BOLD}${BLUE}Autocaliweb Supported Distributions${RESET}

${GREEN}✅ Fully Supported:${RESET}
  - Debian
  - Ubuntu

${YELLOW}⚠️ Experimental:${RESET}
  - Fedora
  - RHEL / CentOS
  - Arch Linux
  - openSUSE / SLES

${RED}❌ Unsupported:${RESET}
  - Anything else (Gentoo, Slackware, Alpine, etc.)

Notes:
- Experimental distros ${BOLD}may${RESET} work, but are not thoroughly tested.
- Only ${BOLD}Debian/Ubuntu${RESET} are guaranteed stable and officially supported.
EOF
}

# --- Mapping: package → binary to check ---
# This map is updated to better reflect the specific packages that provide
# the required command-line binaries on various Linux distributions.
# Experimental: Still needs work
# Associative array
declare -A pkg_bin_map=(
    # --- Core tools ---
    [curl]="curl"
    [wget]="wget"
    [binutils]="ld"
    ["xz-utils"]="xz"
    [xz]="xz"
    ["inotify-tools"]="inotifywait"
    ["xdg-utils"]="xdg-open"

    # --- Networking (netcat variants) ---
    ["netcat-openbsd"]="nc" # apt-get, apk
    ["openbsd-netcat"]="nc" # apt-get, yum, dnf
    ["net-tools"]="nc"      # yum, dnf
    [netcat]="nc"           # pacman
    ["nmap-ncat"]="nc"      # n/a

    # --- Python / pip / venv ---
    [python3]="python3"
    [python]="python3"
    ["python3-dev"]="python3"           # apt-get, apk
    ["python3-devel"]="python3"         # yum, dnf, zypper
    ["python3-pip"]="pip3"              # apt-get, yum, dnf, zypper
    ["py3-pip"]="pip3"                  # apk
    ["python-pip"]="pip"                # pacman
    ["python3-venv"]="python3"          # apt-get, apk
    ["python3-virtualenv"]="virtualenv" # yum, dnf, zypper
    ["python-virtualenv"]="virtualenv"  # pacman
    ["py3-virtualenv"]="virtualenv"     # n/a

    # --- Build tools ---
    ["build-essential"]="gcc"     # apt-get
    ["build-base"]="gcc"          # apk
    ["base-devel"]="gcc"          # pacman
    ["patterns devel-base"]="gcc" # zypper
    [gcc]="gcc"
    [make]="make"
    [automake]="automake"
    ["gcc-c++"]="g++"      # yum, dnf
    ["kernel-devel"]="gcc" # yum, dnf
    [cmake]="cmake"        # all

    # --- Libraries: OpenSSL / LDAP / SASL ---
    ["libssl-dev"]="openssl"              # apt-get
    ["libopenssl-devel"]="openssl"        # yum, dnf, zypper
    ["openssl-devel"]="openssl"           # pacman
    ["openssl-dev"]="openssl"             # apk
    ["libldap2-dev"]="ldapsearch"         # apt-get
    ["openldap-devel"]="ldapsearch"       # yum, dnf, pacman
    ["openldap2-devel"]="ldapsearch"      # zypper
    ["openldap-dev"]="ldapsearch"         # apk
    ["cyrus-sasl-devel"]="sasl-digestmd5" # yum, dnf, zypper
    ["cyrus-sasl-dev"]="sasl-digestmd5"   # apt-get, apk

    # --- Image/PDF processing ---
    [imagemagick]="convert" # apt-get, pacman, apk
    [ImageMagick]="convert" # yum, dnf, zypper
    [ghostscript]="gs"

    # --- Database ---
    [sqlite3]="sqlite3" # apt-get, yum, dnf, zypper
    [sqlite]="sqlite3"  # pacman, apk

    # --- File/magic ---
    [libmagic1]="file" # apt-get, zypper
    [libmagic]="file"  # yum, dnf, pacman
    [file]="file"      # apk

    # --- X11/graphics ---
    [libxi6]="libxi"             # apt-get, zypper
    [libXi]="libxi"              # yum, dnf
    [libxi]="libxi"              # pacman
    ["libxi-dev"]="libxi"        # apk
    ["libxslt1.1"]="xsltproc"    # apt-get
    [libxslt]="xsltproc"         # yum, dnf, pacman
    ["libxslt-devel"]="xsltproc" # zypper
    ["libxslt-dev"]="xsltproc"   # apk

    # Corrected mapping: certutil is in libnss3-tools on Ubuntu/Debian.
    ["libnss3-tools"]="certutil"     # apt-get
    ["mozilla-nss-tools"]="certutil" # zypper
    ["mozilla-nss"]="certutil"       # yum, dnf, zypper
    [nss]="certutil"                 # pacman, apk
    ["nss-dev"]="certutil"           # n/a

    # --- Caching Services (New Entries) ---
    # REDIS
    ["redis-server"]="redis-server.service" # Debian/Ubuntu package name (service name)
    [redis]="vulkey"                        # Fedora /RHEL/Arch/SUSE package name (service name)

    # MEMCACHED
    [memcached]="memcached.service" # Package name across all major distros (service name)
)

# Checking required dependencies
check_dependencies() {
    print_status "Checking required installer dependencies..."

    # Make sure package manager is detected
    if [[ -z "$PKG_MANAGER" ]]; then
        detect_distro_and_package_manager || {
            print_error "Could not detect a supported package manager. Aborting."
            exit 1
        }
    fi

    local pkg_output
    if [[ "$VERBOSE" = "1" || "$DEBUG_MODE" = "1" ]]; then
        pkg_output="/dev/stdout"
    else
        pkg_output="/dev/null"
    fi

    # Refresh package index before checking for missing dependencies
    if [[ "$SKIP_UPDATE" = "0" && "$UPDATE_RAN" = "0" ]]; then
        # Update package lists once
        print_status "Refreshing package index using $PKG_MANAGER..."
        # Convert the base command string into an array
        IFS=' ' read -r -a base_cmd <<<"${PKG_UPDATE_CMD[$PKG_MANAGER]}"

        if ! "${base_cmd[@]}" >"$pkg_output" 2>&1; then
            print_error "Failed to update package index with $PKG_MANAGER"
            exit 1
        fi
        UPDATE_RAN=1
    fi

    # Core dependencies needed by this script for installation
    local core_pkgs
    core_pkgs=(curl git python3 sqlite3 tar zip)
    local missing_deps=()
    for pkg in "${core_pkgs[@]}"; do
        # Use the pkg_bin_map to find the correct binary name
        local bin="${pkg_bin_map[$pkg]:-$pkg}"
        print_verbose "Checking if '$bin' (from '$pkg') exists..."

        if ! command -v "$bin" >/dev/null 2>&1; then
            print_verbose "'$bin' not found → adding '$pkg' to missing dependencies."
            missing_deps+=("$pkg")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_warning "The following core dependencies are missing: ${missing_deps[*]}"
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-accepting install of missing dependencies (--yes flag provided)"
            REPLY="y"
        else
            print_prompt "Do you want to attempt to install these missing dependencies now? (y/n)" REPLY "true"
        fi
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            print_status "Attempting to install missing dependencies with $PKG_MANAGER..."
            if ! install_system_deps "${missing_deps[@]}"; then
                print_error "Failed to install some core dependencies: ${missing_deps[*]}"
                print_error "Please install them manually and re-run the script."
                exit 1
            fi
            print_status "All core dependencies are now installed."
        else
            print_error "Installation aborted. Missing core dependencies: ${missing_deps[*]}"
            print_error "Please install them manually and re-run the script."
            exit 1
        fi
    else
        print_status "All core dependencies found."
    fi
}

# Function to estimate the total required free disk space
# Set TOTAL_SPACE_REQUIRED: The total estimated space required in MiB.
# # Argument $1: if true do heuristic calculation (for --distro-check-only )
# Headless vs Desktop and optional dependencies absence or presence not considered
estimate_total_space_required() {
    local Heuristic="$1"
    TOTAL_SPACE_REQUIRED="${BUFFER_MB}"

    print_verbose "Starting space estimation..."
    print_verbose "Initial buffer: ${BUFFER_MB} MiB"

    if command -v calibre >/dev/null 2>&1; then
        # Calibre is already installed (binary found)
        print_verbose "Calibre binary found. Skipping its installation cost."
    else
        TOTAL_SPACE_REQUIRED=$((TOTAL_SPACE_REQUIRED + CALIBRE_INSTALL_MB))
        TOTAL_SPACE_REQUIRED=$((TOTAL_SPACE_REQUIRED + CALIBRE_ARCHIVE_MB))
        print_verbose "Calibre not found. Adding ${CALIBRE_INSTALL_MB} MiB (install) + ${CALIBRE_ARCHIVE_MB} MiB (archive)."
    fi

    if [[ "$Heuristic" == true ]]; then
        if systemctl status autocaliweb.service >/dev/null 2>&1; then
            print_verbose "Heuristic check: Found autocaliweb.service. Assuming existing installation."
            print_verbose "Skipping initial ACW and System Package costs."
        else
            print_verbose "Heuristic check: autocaliweb.service not found. Assuming new installation."
            TOTAL_SPACE_REQUIRED=$((TOTAL_SPACE_REQUIRED + ACW_INSTALL_MB))
            TOTAL_SPACE_REQUIRED=$((TOTAL_SPACE_REQUIRED + SYS_PKG_INSTALL_MB))
            print_verbose "New installation. Adding ${ACW_INSTALL_MB} MiB (ACW) + ${SYS_PKG_INSTALL_MB} MiB (System Packages)."
        fi
    else
        if [[ "$EXISTING_INSTALLATION" == "true" ]]; then
            # Existing installation means we only account for the minor upgrade/update cost,
            # which is often covered by the general buffer or is considered small enough
            # compared to the initial full install size.
            print_verbose "EXISTING_INSTALLATION is true. Skipping initial ACW and System Package costs."
        else
            # New installation, include the full estimated space for Autocaliweb and System Packages
            TOTAL_SPACE_REQUIRED=$((TOTAL_SPACE_REQUIRED + ACW_INSTALL_MB))
            TOTAL_SPACE_REQUIRED=$((TOTAL_SPACE_REQUIRED + SYS_PKG_INSTALL_MB))
            print_verbose "New installation. Adding ${ACW_INSTALL_MB} MiB (ACW) + ${SYS_PKG_INSTALL_MB} MiB (System Packages)."
        fi
    fi
    print_verbose "Estimated total required space: ${TOTAL_SPACE_REQUIRED} MiB"
}

# Check disk space for a target path (or its nearest existing parent)
# Arguments:
#   $1: required_space_mb (integer)
#   $2: target_path_for_check (string)
#   $3: context_message (optional string)
#   $4: dry_run (optional: "1" = warn only, "0" or unset = enforce)
check_disk_space() {
    local required_space_mb="$1"
    local target_path_for_check="$2"
    local context_message="$3"
    local dry_run="${ALLOW_LOW_SPACE:-0}" # default enforce

    if [ -z "$required_space_mb" ] || [ -z "$target_path_for_check" ]; then
        print_error "Internal error: check_disk_space called without required arguments."
        exit 1
    fi

    # Walk up the path until we find something that exists
    local check_path="$target_path_for_check"
    while [ ! -e "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path=$(dirname "$check_path")
    done

    if [ ! -e "$check_path" ]; then
        print_error "Could not resolve any valid parent for '$target_path_for_check'."
        return 1
    fi

    if [ "$check_path" != "$target_path_for_check" ]; then
        print_warning "Target path '$target_path_for_check' does not exist yet. Falling back to '$check_path' for disk space check."
    fi

    # Use df -k to get available space in 1KB blocks
    local available_space_kb
    available_space_kb=$(df -P -k "$check_path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$available_space_kb" ]; then
        print_error "Failed to check disk space for '$check_path'."
        return 1
    fi

    local available_space_mb=$((available_space_kb / 1024)) # Convert KB to MB
    local message_prefix=""
    if [ -n "$context_message" ]; then
        message_prefix="${context_message}: "
    fi

    if [ "$available_space_mb" -lt "$required_space_mb" ]; then
        if [ "$dry_run" -eq 1 ]; then
            print_warning "${message_prefix}Insufficient disk space on '${check_path}'. Required: ${required_space_mb} MB, Available: ${available_space_mb} MB (dry run mode, continuing anyway)."
            return 0
        else
            print_error "${message_prefix}Insufficient disk space on '${check_path}'. Required: ${required_space_mb} MB, Available: ${available_space_mb} MB"
            print_status "Please free up space or use ${BOLD}--allow-low-space${RESET} to bypass this check."
            exit 1
        fi
    fi

    print_status "${message_prefix}Disk space check passed for '${GREEN}${check_path}${RESET}': ${available_space_mb} MB available (required ${required_space_mb} MB)."
    return 0
}

# Helper function to get the total size of multiple directories in MB
# Arguments:
#   $@: one or more directory paths
# Returns:
#   echoes the total size in MB (integer)
get_total_directory_size_mb() {
    local total_size_mb=0
    local dir="$1"
    local du_output # Store du output to process line by line
    [[ -d "$dir" ]] || {
        echo 0
        return
    } # if not a directory → size = 0

    # Use du -s --block-size=1M to get total size for each dir directly in MB
    # Suppress errors if a directory doesn't exist (2>/dev/null)
    du_output=$(du -s --block-size=1M "$@" 2>/dev/null)

    # Parse each line of du output. Example line: "123M /path/to/dir"
    # We use awk here to extract the number and sum it up
    local current_line_mb
    while IFS= read -r line; do
        current_line_mb=$(echo "$line" | awk '{print $1}' | sed 's/M//') # Extract number, remove 'M'
        total_size_mb=$((total_size_mb + current_line_mb))
    done <<<"$du_output"

    echo "$total_size_mb"
}

check_system_requirements() {
    if ! systemctl --version >/dev/null 2>&1; then
        print_error "systemd is required but not found"
        exit 1
    else
        systemd_version=$(systemctl --version | head -n1 | awk '{print $2}')
        print_status "Detected systemd version: ${GREEN}${systemd_version}${RESET}"
        # Debian 10+, Ubuntu 20.04+, CentOS 8+, Fedora, Arch, etc.) ship with systemd ≥ 240.
        # systemctl edit or advanced sandboxing options need ≥ 245 (Ubuntu 20.04+ and Debian 11+)
        min_version=240
        if ((systemd_version < min_version)); then
            print_error "systemd version $systemd_version is too old. Minimum required is $min_version."
            exit 1
        fi
    fi
    # Check Python version
    # We need python version to craft packages for openSUSE
    PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"; then
        print_error "Python 3.10+ required, found $PYTHON_VERSION"
        exit 1
    else
        print_status "Python check passed: Python version ${GREEN}${PYTHON_VERSION}${RESET}"
    fi
    # Check RAM
    total_ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
    min_ram_mb=1024 # require 1 GB a safe baseline.
    if ((total_ram_mb < min_ram_mb)); then
        print_error "At least ${min_ram_mb} MB RAM is required (found ${total_ram_mb} MB)"
        exit 1
    else
        print_status "RAM check passed: ${GREEN}${total_ram_mb}${RESET} MB available"
    fi
}

# backup_files - Backs up one or more files to the user's home directory.
# Arguments:
#   $@: (string) - A list of absolute file paths to back up.
# Behavior:
#   - Copies each file to the user's home directory.
#   - Appends a timestamp to the new file name.
#   - Sets ownership of the new file to the current user.
backup_files() {
    local files=("$@")
    local backup_file
    local ts
    ts=$(date +%Y%m%d_%H%M%S)

    if [[ ! -d "$USER_HOME" ]]; then
        print_error "User home directory not found for $REAL_USER"
        return 1
    fi

    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            local base
            base=$(basename "$f")
            backup_file="$USER_HOME/${base}.backup.$ts"
            if cp "$f" "$backup_file"; then
                chown "$REAL_UID:$REAL_GID" "$backup_file"
                print_status "$base: Database backed up to: $backup_file"
            else
                print_error "Failed to back up $f"
            fi
        else
            print_debug "Skipping $f (not found)"
        fi
    done
}

stop_autocaliweb_service() {
    print_status "Attempting robust stop of 'autocaliweb.service' and cleanup for user '$SERVICE_USER'..."

    # Stop the main service via systemctl (prevents restarts)
    if command -v systemctl &>/dev/null && systemctl is-active --quiet autocaliweb.service; then
        print_status "Stopping systemd service 'autocaliweb.service'..."
        # If the stop fails, we still proceed to PID cleanup
        if ! systemctl stop autocaliweb.service; then
            print_warning "Failed to cleanly stop 'autocaliweb.service' via systemctl. Proceeding to PID cleanup."
        else
            # Give the service manager a moment to cleanly terminate its children
            sleep 2
        fi
    fi

    # Check for and kill any remaining processes for the service user and script.
    local pids_to_kill
    pids_to_kill=$(pgrep -u "$SERVICE_USER" -f "$INSTALL_DIR/scripts/ingest_watcher.sh" 2>/dev/null)

    if [[ -n "$pids_to_kill" ]]; then
        print_warning "Found persistent PIDs for '$SERVICE_USER' after service stop attempt: ${pids_to_kill//\\n/, }"

        local attempt=0
        local max_attempts=3
        local pids_still_running

        while [[ "$attempt" -lt "$max_attempts" ]]; do
            attempt=$((attempt + 1))

            if [ "$attempt" -eq 1 ]; then
                # Attempt 1: SIGTERM (Graceful kill)
                print_status "Attempt $attempt: Sending SIGTERM to PIDs: ${pids_to_kill//\\n/, }"
                kill -TERM "$pids_to_kill" 2>/dev/null || true
            else
                # Attempts 2 & 3: SIGKILL (Forceful kill)
                print_error "Attempt $attempt: Forcing kill (SIGKILL) on PIDs: ${pids_to_kill//\\n/, }"
                kill -KILL "$pids_to_kill" 2>/dev/null || true
            fi

            sleep 1
            # Recheck for processes, using the user and the specific script path for precision
            pids_still_running=$(pgrep -u "$SERVICE_USER" -f "$INSTALL_DIR/scripts/ingest_watcher.sh" 2>/dev/null)

            if [[ -z "$pids_still_running" ]]; then
                print_status "Successfully terminated all processes for '$SERVICE_USER'."
                return 0
            fi

            pids_to_kill="$pids_still_running"
            if [ "$attempt" -lt "$max_attempts" ]; then
                print_warning "Processes still running after attempt $attempt. Retrying..."
            fi
        done

        # Final failure state after max attempts
        print_error "Failed to terminate all processes for user '$SERVICE_USER'. PIDs: ${pids_to_kill//\\n/, }"
        return 1
    else
        print_status "No running processes found for '$SERVICE_USER' related to the service."
        return 0
    fi
}

_stop_user_processes() {
    print_status "Attempting to stop all processes for user ${BOLD}$SERVICE_USER${RESET}..."
    local running_pids
    local kill_count=0

    # Run the kill loop up to 3 times to fight systemd respawn race condition
    for attempt in 1 2 3; do
        running_pids=$(pgrep -u "$SERVICE_USER" || echo "")

        if [ -z "$running_pids" ]; then
            if [ $kill_count -gt 0 ]; then
                # Only print this if we actually killed something earlier
                print_status "All user processes successfully terminated."
            else
                print_status "No running processes found for ${SERVICE_USER}."
            fi
            # Add a small delay for good measure before proceeding to usermod
            sleep 0.5
            return 0
        fi

        if [ $attempt -eq 1 ]; then
            # Replace newlines with commas for cleaner output on the first attempt
            print_warning "Found running processes for ${SERVICE_USER}: ${running_pids//$'\n'/, }"
        else
            print_warning "Processes still running after attempt $((attempt - 1)). Re-killing..."
        fi

        kill_count=$((kill_count + 1))

        # 1. Attempt graceful termination (SIGTERM)
        sudo kill -TERM "$running_pids" 2>/dev/null || true
        sleep 1 # Wait for processes to die gracefully

        # 2. Forceful kill (SIGKILL) if still running
        running_pids=$(pgrep -u "$SERVICE_USER" || echo "")
        if [ -n "$running_pids" ]; then
            print_error "Forcing kill (SIGKILL) on: ${running_pids//$'\n'/, }"
            sudo kill -KILL "$running_pids" 2>/dev/null || print_error "Failed to kill processes. Manual intervention required."
            sleep 1 # Wait for OS to clean up after SIGKILL
        fi
    done

    # Final check after all attempts
    running_pids=$(pgrep -u "$SERVICE_USER" || echo "")
    if [ -n "$running_pids" ]; then
        print_error "Failed to terminate all processes for user ${SERVICE_USER}. Process IDs: ${running_pids//$'\n'/, }"
        return 1
    fi

    return 0
}

ultimate_service_stop() {
    SYSTEMCTL_SERVICE_NAME="acw-ingest-service.service"
    TARGET_SCRIPT_PATH="$INSTALL_DIR/scripts/ingest_watcher.sh"

    print_status "Executing ultimate stop procedure for '$SYSTEMCTL_SERVICE_NAME' for user '$SERVICE_USER'..."
    local final_status=0

    # 1. ATTEMPT TO STOP AND DISABLE THE SERVICE UNIT
    # Stopping prevents the immediate start. Disabling removes the link, preventing a restart on reboot.
    if command -v systemctl &>/dev/null; then
        if sudo systemctl is-active --quiet "$SYSTEMCTL_SERVICE_NAME"; then
            print_status "1a. Stopping systemd service '$SYSTEMCTL_SERVICE_NAME'..."
            # Try to stop the active service
            if ! sudo systemctl stop "$SYSTEMCTL_SERVICE_NAME"; then
                print_error "Systemd stop FAILED. This means the service may respawn instantly."
                final_status=1
            fi
        fi

        # We proceed to mask/disable the unit to guarantee it cannot restart
        if sudo systemctl is-enabled --quiet "$SYSTEMCTL_SERVICE_NAME"; then
            print_status "1b. Disabling service unit to prevent immediate re-activation."
            # Disabling or masking is critical to win the respawn race
            sudo systemctl disable "$SYSTEMCTL_SERVICE_NAME" 2>/dev/null || print_warning "Failed to disable service unit (ignoring)."
        fi
    fi

    # Give systemd a moment to process the stop/disable command
    sleep 1.5

    # 2. RELENTLESS PKILL LOOP
    local attempt=0
    local max_attempts=30

    while [[ "$attempt" -lt "$max_attempts" ]]; do
        attempt=$((attempt + 1))

        # pgrep to find processes that match the user and the exact script path
        local current_pids
        current_pids=$(pgrep -u "$SERVICE_USER" -f "$TARGET_SCRIPT_PATH" || echo "")

        if [[ -z "$current_pids" ]]; then
            print_status "SUCCESS: All processes for '$SERVICE_USER' terminated after $attempt attempts."
            # Set status back to 0 if the kill succeeded
            final_status=0
            return 0
        fi

        # Use pkill with SIGKILL (-9) for atomic, forceful termination
        print_error "Attempt $attempt: Forcing kill (SIGKILL) on PIDs: ${current_pids//\\n/, }"

        # pkill is more reliable than kill with a list of PIDs in a race condition
        sudo pkill -KILL -u "$SERVICE_USER" -f "$TARGET_SCRIPT_PATH" 2>/dev/null || true

        sleep 1 # Wait for processes to die
    done

    # 3. FINAL CHECK
    final_pids=$(pgrep -u "$SERVICE_USER" -f "$TARGET_SCRIPT_PATH" || echo "")
    if [ -n "$final_pids" ]; then
        print_error "FAILED: Could not terminate PIDs after all attempts: ${final_pids//\\n/, }"
        final_status=1
    fi

    return $final_status
}

# Re-configures an existing service user, specifically to set the home directory
# for a legacy installation where it may not have been set correctly.
reconfigure_service_user() {
    print_status "Service user '$SERVICE_USER' already exists. Re-configuring it..."
    ultimate_service_stop
    # _stop_user_processes
    #stop_autocaliweb_service
    # Get the current home directory of the service user.
    local current_home
    current_home=$(getent passwd "$SERVICE_USER" | cut -d: -f6)

    # Check if the home directory is set to a default "nonexistent" path.
    if [ "$current_home" = "/nonexistent" ]; then
        print_status "Setting home directory for service user '$SERVICE_USER' to '$CONFIG_DIR'..."
        usermod -d "$CONFIG_DIR" "$SERVICE_USER" || {
            print_error "Failed to re-configure service user home directory. Aborting."
            exit 1
        }
    else
        print_status "Service user '$SERVICE_USER' already has a home directory set to '$current_home'. Leaving it as-is."
    fi
}

# Prepare the entire environment for the service, including user/group creation and configuration.
# Combine create_service_user() and configure_user_and_plugins() in one function.
# Now the service user's home directory is correctly set.
# The 'env HOME="..."' part is no longer needed for every command in setup_autocaliweb().
prepare_service_environment() {
    print_status "Configuring user groups and Calibre plugins..."

    # Check if the service user already exists. If not, create it.
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        print_status "Service user '$SERVICE_USER' not found. Creating it..."
        # Create a system user with a non-login shell and a specific home directory
        useradd -r -s /bin/false -d "$CONFIG_DIR" "$SERVICE_USER" || {
            print_error "Failed to create service user. Aborting."
            exit 1
        }
    else
        reconfigure_service_user
    fi

    # Check if the service group already exists. If not, create it.
    if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        print_status "Service group '$SERVICE_GROUP' not found. Creating it..."
        groupadd "$SERVICE_GROUP" || {
            print_error "Failed to create service group. Aborting."
            exit 1
        }
    else
        print_status "Service group '$SERVICE_GROUP' already exists. Skipping creation."
    fi

    # Add the service user to the service group.
    usermod -a -G "$SERVICE_GROUP" "$SERVICE_USER" || {
        print_error "Failed to add service user to its own group. Aborting."
        exit 1
    }

    # Check if the service user and the real user are different.
    if [ "$REAL_USER" != "$SERVICE_USER" ]; then
        print_status "Adding real user '$REAL_USER' to service group '$SERVICE_GROUP'..."
        usermod -a -G "$SERVICE_GROUP" "$REAL_USER" || {
            print_error "Failed to add user to group. Aborting."
            exit 1
        }

        print_status "Adding service user '$SERVICE_USER' to real user's group '$REAL_GROUP'..."
        usermod -a -G "$REAL_GROUP" "$SERVICE_USER" || {
            print_error "Failed to add service user to group. Aborting."
            exit 1
        }
    else
        print_status "Real user and service user are the same ('$REAL_USER'). Skipping group membership adjustments."
    fi

    # Create the target directory first
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 2775 "$CONFIG_DIR/.config/calibre/plugins"

    # Check if the real user has a Calibre plugins directory
    if [ -d "/home/$REAL_USER/.config/calibre/plugins" ]; then
        print_status "Copying Calibre plugins from /home/$REAL_USER..."

        # Copy only regular files and directories, not symlinks
        # Use rsync or find to avoid copying symlinks (Avoid the freaking recursive link)
        rsync -a --no-links "/home/$REAL_USER/.config/calibre/plugins/" "$CALIBRE_PLUGIN_DIR/" 2>/dev/null ||
            find "/home/$REAL_USER/.config/calibre/plugins/" -maxdepth 1 -type f -o -type d -mindepth 1 -exec cp -r {} "$CALIBRE_PLUGIN_DIR/" \; 2>/dev/null || true
    else
        print_status "Calibre plugins not found in the home directory. Skipping copy."
    fi

    # Create the symbolic link for convenience (remove any existing one first)
    rm -f "$CONFIG_DIR/calibre_plugins"
    ln -sf "$CALIBRE_PLUGIN_DIR" "$CONFIG_DIR/calibre_plugins"

    print_status "User groups and Calibre plugins configured successfully!"
}

# Create main directories
create_acw_directories() {
    print_status "Creating directories for user: $SERVICE_USER ($SERVICE_USER:$SERVICE_GROUP)"
    # setgid bit 2 ensures new files/subdirectories automatically inherit the group of the parent.
    # Directories with restrictive permissions (2755) - no group write
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2755 "$INSTALL_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2755 "$CONFIG_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2755 "$CALIBRE_PLUGIN_DIR"

    # Directories with relaxed permissions (2775) - group write needed
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "$CALIBRE_LIB_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "$INGEST_DIR"

    # Create processed_books base directory first
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "$PROCESSED_BOOKS_BASE"

    # Create subdirectories under processed_books
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "${PROCESSED_BOOKS_BASE}/converted"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "${PROCESSED_BOOKS_BASE}/imported"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "${PROCESSED_BOOKS_BASE}/failed"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "${PROCESSED_BOOKS_BASE}/fixed_originals"

    # Create other temporary/log directories with group write access
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "$LOG_ARCHIVE_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "$CONVERSION_TMP_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "$METADATA_CHANGE_LOGS_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 "$METADATA_TEMP_DIR"

    ln -sf "${INGEST_DIR}" "${USER_HOME}" || true # create link for ingest-dir

    print_status "Directory structure created successfully!"
}

migrate_legacy_venv() {
    if [ -d "$INSTALL_DIR/venv" ] && [ ! -d "$INSTALL_DIR/.venv" ]; then
        print_status "Migrating legacy 'venv/' → '.venv/'"
        mv "$INSTALL_DIR/venv" "$INSTALL_DIR/.venv" || {
            print_error "Failed to migrate legacy venv directory. Aborting."
            exit 1
        }
    fi
}

_cleaning_python_bytecode() {
    local deleted_file_count=0
    local deleted_dir_count=0

    # --- 1. Find and count *.pyc files ---
    # Use find to locate files and print them to stdout, which is piped to tee.
    # tee saves the list to a temporary file (or /dev/stderr for immediate output),
    # while piping to wc -l gets the count.
    # We then use a second find command to execute the actual deletion.
    # NOTE: The command substitution $(...) must be handled carefully when using -delete.

    # To be safe and get the count, we use the following pattern:
    if [[ "$DEBUG" = "1" ]]; then
        # In debug mode, find prints the paths, and we count them.
        print_status "Searching for *.pyc files to delete in $LEGACY_INSTALL_DIR..."

        # Execute find once to count files, outputting them to the screen
        # Use find with -delete last for safety, but run a separate find for printing and counting.
        deleted_file_count=$(find "$LEGACY_INSTALL_DIR" -type f -name "*.pyc" -print 2>/dev/null | tee /dev/stderr | wc -l)

        # Execute the actual deletion silently
        find "$LEGACY_INSTALL_DIR" -type f -name "*.pyc" -delete 2>/dev/null

        # Find and delete __pycache__ directories
        deleted_dir_count=$(find "$LEGACY_INSTALL_DIR" -type d -name "__pycache__" -empty -print 2>/dev/null | tee /dev/stderr | wc -l)
        find "$LEGACY_INSTALL_DIR" -type d -name "__pycache__" -empty -delete 2>/dev/null

    else
        # Non-debug mode: Execute deletion and count silently.
        deleted_file_count=$(find "$LEGACY_INSTALL_DIR" -type f -name "*.pyc" -print 2>/dev/null | wc -l)
        find "$LEGACY_INSTALL_DIR" -type f -name "*.pyc" -delete 2>/dev/null

        deleted_dir_count=$(find "$LEGACY_INSTALL_DIR" -type d -name "__pycache__" -empty -print 2>/dev/null | wc -l)
        find "$LEGACY_INSTALL_DIR" -type d -name "__pycache__" -empty -delete 2>/dev/null
    fi

    # --- 2. Report the result ---
    if [[ "$deleted_file_count" -gt 0 || "$deleted_dir_count" -gt 0 ]]; then
        print_status "Python bytecode cleanup complete. Deleted ${deleted_file_count} file(s) and ${deleted_dir_count} directory(s)."
    else
        print_status "Python bytecode cleanup complete. No bytecode files found."
    fi
}

update_app_db_settings() {
    migration_log="$1"
    print_status "Updating database paths and binary settings..." "$migration_log"

    # TODO: deal with Runtime error near line 1: database is locked (5)
    # Selectively update only binary paths and essential settings, preserving user data
    # Detect binary paths (needed every time)
    KEPUBIFY_PATH=$(which kepubify 2>/dev/null || echo "/usr/bin/kepubify")
    EBOOK_CONVERT_PATH=$(which ebook-convert 2>/dev/null || echo "/usr/bin/ebook-convert")
    CALIBRE_BIN_DIR=$(dirname "$EBOOK_CONVERT_PATH")

    if [ ! -f "$CONFIG_DIR/app.db" ]; then
        print_warning "Database not found at $CONFIG_DIR/app.db. Skipping settings update." "$migration_log"
        return 1
    fi
    print_status "Updating binary paths while preserving user settings..."
    # Get current settings to check what needs updating
    CURRENT_LOGFILE=$(sqlite3 "$CONFIG_DIR/app.db" "SELECT config_logfile FROM settings LIMIT 1;" 2>/dev/null || echo "")
    CURRENT_ACCESS_LOGFILE=$(sqlite3 "$CONFIG_DIR/app.db" "SELECT config_access_logfile FROM settings LIMIT 1;" 2>/dev/null || echo "")
    CURRENT_CALIBRE_DIR=$(sqlite3 "$CONFIG_DIR/app.db" "SELECT config_calibre_dir FROM settings LIMIT 1;" 2>/dev/null || echo "")

    # Always update binary paths (safe to overwrite)
    sqlite3 "$CONFIG_DIR/app.db" <<EOS
UPDATE settings SET
    config_kepubifypath='$KEPUBIFY_PATH',
    config_converterpath='$EBOOK_CONVERT_PATH',
    config_binariesdir='$CALIBRE_BIN_DIR'
WHERE 1=1;
EOS

    # --- LOG FILE CHECK ---
    # Invalid if: Empty OR relative name OR starts with /tmp OR is Docker path (/config/...)
    if [[ -z "$CURRENT_LOGFILE" ]] ||
        [[ "$CURRENT_LOGFILE" == "autocaliweb.log" ]] ||
        [[ "$CURRENT_LOGFILE" == "/tmp/autocaliweb.log" ]] ||
        [[ "$CURRENT_LOGFILE" == "/config/autocaliweb.log" ]]; then

        sqlite3 "$CONFIG_DIR/app.db" "UPDATE settings SET config_logfile='$CONFIG_DIR/autocaliweb.log' WHERE 1=1;"
        print_status "Updated log file path to $CONFIG_DIR/autocaliweb.log (Previous was invalid: '$CURRENT_LOGFILE')" "$migration_log"
    else
        print_status "Preserving existing log file setting: $CURRENT_LOGFILE" "$migration_log"
    fi

    # --- ACCESS LOG CHECK ---
    # Invalid if: Empty OR relative name OR starts with /tmp OR is Docker path (/config/...)
    if [[ -z "$CURRENT_ACCESS_LOGFILE" ]] ||
        [[ "$CURRENT_ACCESS_LOGFILE" == "access.log" ]] ||
        [[ "$CURRENT_ACCESS_LOGFILE" == "/tmp/access.log" ]] ||
        [[ "$CURRENT_ACCESS_LOGFILE" == "/config/access.log" ]]; then

        sqlite3 "$CONFIG_DIR/app.db" "UPDATE settings SET config_access_logfile='$CONFIG_DIR/access.log' WHERE 1=1;"
        print_status "Updated access log file path to $CONFIG_DIR/access.log (Previous was invalid: '$CURRENT_ACCESS_LOGFILE')" "$migration_log"
    else
        print_status "Preserving existing access log file setting: $CURRENT_ACCESS_LOGFILE" "$migration_log"
    fi

    # --- CALIBRE DIR CHECK ---
    # Invalid if: Empty OR Root '/' OR Docker path '/calibre' OR Directory doesn't exist on this system
    # Note: Checking if directory exists (! -d) is risky if the drive isn't mounted yet,
    # but for our installer, it's a safe assumption that the library should be there.
    if [[ -z "$CURRENT_CALIBRE_DIR" ]] ||
        [[ "$CURRENT_CALIBRE_DIR" == "/" ]] ||
        [[ "$CURRENT_CALIBRE_DIR" == "/calibre" ]] ||
        [[ ! -d "$CURRENT_CALIBRE_DIR" ]]; then

        sqlite3 "$CONFIG_DIR/app.db" "UPDATE settings SET config_calibre_dir='$CALIBRE_LIB_DIR' WHERE 1=1;"
        print_status "Updated Calibre library directory to $CALIBRE_LIB_DIR (Previous was invalid/missing: '$CURRENT_CALIBRE_DIR')" "$migration_log"
    else
        print_status "Preserving existing Calibre library setting: $CURRENT_CALIBRE_DIR" "$migration_log"
    fi

    # Set UNRAR_PATH
    local SQL_UPDATE
    SQL_UPDATE="UPDATE settings SET config_rarfile_location='${UNRAR_PATH}' WHERE 1=1;"
    sqlite3 "$CONFIG_DIR/app.db" "$SQL_UPDATE"
    print_status "Adding RAR utility at: $UNRAR_PATH to the application settings." "$migration_log"

    print_status "Database settings configured." "$migration_log"
    return 0
}

migrate_existing_installation() {
    local components_to_migrate=("$@") # Capture all arguments into an array
    local migration_log

    if [[ "$LOG_FILE" == "" ]]; then
        MIGRATION_LOG_BASE_DIR="/tmp"
    else
        MIGRATION_LOG_BASE_DIR=$(dirname "$LOG_FILE")
    fi
    migration_log="${MIGRATION_LOG_BASE_DIR}/acw_migration_$(date +%Y%m%d_%H%M%S).log"

    # Start the log with an initial header
    echo "Autocaliweb Migration Log - Started at $(date)" >"$migration_log"
    echo "--------------------------------------------------------" >>"$migration_log"
    print_status "Starting migration log..." "$migration_log"
    print_verbose "Old Install Dir: $LEGACY_INSTALL_DIR" "$migration_log"
    print_verbose "Old Config Dir:  $LEGACY_CONFIG_DIR" "$migration_log"
    print_verbose "Old Calibre Lib: $LEGACY_CALIBRE_LIB_DIR" "$migration_log"
    print_verbose "New Install Dir: $INSTALL_DIR" "$migration_log"
    print_verbose "New Config Dir:  $CONFIG_DIR" "$migration_log"
    print_verbose "New Calibre Lib: $CALIBRE_LIB_DIR" "$migration_log"
    print_status "Components to Migrate: ${components_to_migrate[*]}" "$migration_log"
    echo "--------------------------------------------------------" >>"$migration_log"
    print_status "Starting migration for: ${components_to_migrate[*]}..." "$migration_log"

    # Ensure SERVICE_USER and SERVICE_GROUP all set before creating any directories
    prepare_service_environment
    # Ensure target directories exist before migration (crucial for cp)
    print_status "Ensuring target directories exist..." "$migration_log"
    create_acw_directories

    print_status "Target directories created: $INSTALL_DIR, $CONFIG_DIR, $CALIBRE_LIB_DIR, $INGEST_DIR." "$migration_log"

    local files_to_backup=()
    for component in "${components_to_migrate[@]}"; do
        case "$component" in
            "app_source")
                # No single DB file for app source, skip, (for future use)
                ;;
            "config_data")
                files_to_backup+=("$LEGACY_CONFIG_DIR/app.db" "$LEGACY_CONFIG_DIR/acw.db" "$LEGACY_CONFIG_DIR/gdrive.db")
                ;;
            "calibre_library")
                files_to_backup+=("$LEGACY_CALIBRE_LIB_DIR/metadata.db" "$LEGACY_CALIBRE_LIB_DIR/.calnotes/notes.db")
                ;;
        esac
    done

    if [[ ${#files_to_backup[@]} -gt 0 ]]; then
        backup_files "${files_to_backup[@]}"
        print_verbose "Starting backup for: ${files_to_backup[*]}..." "$migration_log"
    else
        print_debug "No database files detected for backup." "$migration_log"
    fi

    # Define the rsync command template -a: archive mode, -h: human-readable numbers
    # -a equivalent to -rlptgoD (-r recursive, -l links, -p perms, -t times, -g group, -o owner, -D devices)
    RSYNC_BASE_CMD=(rsync -ah)

    # If DEBUG_MODE is 1, add -v (verbose) to rsync to show file listings.
    if [[ "$DEBUG_MODE" = "1" ]]; then
        RSYNC_BASE_CMD+=(-v)
    fi

    for component in "${components_to_migrate[@]}"; do
        case "$component" in
            "app_source")
                local app_rsync_cmd
                print_status "Migrating application source from ${LEGACY_INSTALL_DIR} to ${INSTALL_DIR}..." "$migration_log"
                if [[ -n "$LEGACY_INSTALL_DIR" ]] && [[ "$LEGACY_INSTALL_DIR" != "$INSTALL_DIR" ]]; then
                    _cleaning_python_bytecode
                    print_status "Initiating file transfer for application source. This may take a while." "$migration_log"
                    app_rsync_cmd=("${RSYNC_BASE_CMD[@]}" "$LEGACY_INSTALL_DIR/" "$INSTALL_DIR/")
                    print_verbose "${app_rsync_cmd[*]} '$LEGACY_INSTALL_DIR/' '$INSTALL_DIR/'" "$migration_log"
                    if run_with_progress "${app_rsync_cmd[@]}" 2>&1 | tee -a "$migration_log"; then
                        print_verbose "Setting permissions on new application directory..." "$migration_log"
                        print_verbose "chown -R '$SERVICE_USER:$SERVICE_GROUP' '$INSTALL_DIR'" "$migration_log"
                        chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
                        print_status "Application source migration complete." "$migration_log"
                        IS_LEGACY_MIGRATION=true
                    else
                        print_error "Failed to migrate application source." "$migration_log"
                        exit 1
                    fi
                else
                    print_status "Application source migration skipped (source not found or target is same as old)." "$migration_log"
                fi
                ;;
            "config_data")
                print_status "Migrating configuration data from ${LEGACY_CONFIG_DIR} to ${CONFIG_DIR}..." "$migration_log"
                if [[ -n "$LEGACY_CONFIG_DIR" ]] && [[ "$LEGACY_CONFIG_DIR" != "$CONFIG_DIR" ]]; then
                    print_verbose "Initiating file transfer for configuration data. This should be fast." "$migration_log"
                    print_debug "rsync -ah --progress '$LEGACY_CONFIG_DIR/' '$CONFIG_DIR/'" "$migration_log"
                    # Use tee to both display progress and log it.
                    if rsync -ah --progress "$LEGACY_CONFIG_DIR/" "$CONFIG_DIR/" 2>&1 | tee -a "$migration_log"; then
                        print_verbose "Setting permissions on new configuration directory..." "$migration_log"
                        print_debug "chown -R '$SERVICE_USER:$SERVICE_GROUP' '$CONFIG_DIR'" "$migration_log"
                        chown -R "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR"
                        print_status "Configuration data migration complete." "$migration_log"
                        # Update database paths if config was migrated
                        print_status "Updating database paths post-migration..."
                        # Assumes the old app.db is now located at $CONFIG_DIR/app.db
                        update_app_db_settings "$migration_log"
                        print_status "Database paths updated successfully for new structure."

                        IS_LEGACY_MIGRATION=true
                    else
                        print_error "Failed to migrate configuration data." "$migration_log"
                    fi
                else
                    print_status "Configuration data migration skipped (source not found or target is same as old)." "$migration_log"
                fi
                ;;
            "calibre_library")
                local library_rsync_cmd
                print_status "Migrating Calibre library from ${LEGACY_CALIBRE_LIB_DIR} to ${CALIBRE_LIB_DIR}..." "$migration_log"
                if [[ -s "${CALIBRE_LIB_DIR}/metadata.db" ]]; then
                    print_prompt "Target folder not empty, metadata.db exists, do you want to overwrite it? (y/n)" REPLY "true"
                    echo
                    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                        print_error "Migrating Calibre library cancelled by user."
                        continue
                    fi
                fi

                if [[ -n "$LEGACY_CALIBRE_LIB_DIR" ]] && [[ "$LEGACY_CALIBRE_LIB_DIR" != "$CALIBRE_LIB_DIR" ]]; then
                    print_status "Initiating file transfer for Calibre library. This may take a long time." "$migration_log"
                    # Build the final rsync command for library migration
                    library_rsync_cmd=("${RSYNC_BASE_CMD[@]}" "$LEGACY_CALIBRE_LIB_DIR/" "$CALIBRE_LIB_DIR/")
                    print_verbose "${RSYNC_BASE_CMD[*]} '$LEGACY_CALIBRE_LIB_DIR/' '$CALIBRE_LIB_DIR/'" "$migration_log"
                    # Use tee to both display progress and log it.
                    if run_with_progress "${library_rsync_cmd[@]}" 2>&1 | tee -a "$migration_log"; then
                        print_verbose "Setting permissions on new Calibre library..." "$migration_log"
                        print_debug "chown -R '$SERVICE_USER:$SERVICE_GROUP' '$CALIBRE_LIB_DIR'" "$migration_log"
                        chown -R "$SERVICE_USER:$SERVICE_GROUP" "$CALIBRE_LIB_DIR"
                        print_status "Calibre library migration complete." "$migration_log"
                        IS_LEGACY_MIGRATION=true
                    else
                        print_error "Failed to migrate Calibre library." "$migration_log"
                    fi
                else
                    print_status "Calibre library migration skipped (source not found or target is same as old)." "$migration_log"
                fi
                ;;
            *)
                print_warning "Unknown component specified for migration: '$component'." "$migration_log"
                ;;
        esac
    done

    print_status "All requested migrations completed successfully." "$migration_log"
    echo "Migration completed at $(date)" >>"$migration_log"
    print_status "Migration log saved to: ${CYAN}$migration_log${RESET}"
    print_status "You can delete folders ${LEGACY_INSTALL_DIR} ${LEGACY_CONFIG_DIR} to save space. "
}

# Fetches the config_calibre_dir from an SQLite database if the file exists.
get_db_calibre_dir() {
    local db_path="$1"
    if [[ -f "$db_path" ]]; then
        sqlite3 "$db_path" 'SELECT config_calibre_dir FROM settings;' 2>/dev/null
    fi
}

detect_existing_legacy_installation() {
    print_status "Checking for existing installations..."

    local needs_migration=false # Flag to know if ANY migration is needed
    local migrate_components=() # Array to store which components need migrating

    # ----------------------------------------------------
    # OLD LOGIC: Proceed with Docker-to-Native Migration Check
    # ----------------------------------------------------

    # Flags to determine if a specific component needs migration (old path != new path)
    local migrate_app_source=false
    local migrate_config_data=false
    local migrate_calibre_library=false
    #shellcheck disable=SC2034 # SERVICE_USER is not used later, but keep flag for completeness
    local migrate_service_user=false

    print_verbose "Comparing new paths to old Docker-style defaults..."
    if [[ "$INSTALL_DIR" != "$LEGACY_INSTALL_DIR" ]]; then
        migrate_app_source=true
        print_debug "Detected application path change. Old: $LEGACY_INSTALL_DIR, New: $INSTALL_DIR"
    fi
    if [[ "$CONFIG_DIR" != "$LEGACY_CONFIG_DIR" ]]; then
        migrate_config_data=true
        print_debug "Detected config path change. Old: $LEGACY_CONFIG_DIR, New: $CONFIG_DIR"
    fi
    if [[ "$CALIBRE_LIB_DIR" != "$LEGACY_CALIBRE_LIB_DIR" ]]; then
        migrate_calibre_library=true
        print_debug "Detected Calibre library path change. Old: $LEGACY_CALIBRE_LIB_DIR, New: $CALIBRE_LIB_DIR"
    fi
    if [[ "$LEGACY_SERVICE_USER" != "$SERVICE_USER" ]]; then
        #shellcheck disable=SC2034
        migrate_service_user=true
        print_debug "Detected service user change. Old: $LEGACY_SERVICE_USER, New: $SERVICE_USER"
    fi

    print_status "Verifying existence of legacy components..."

    # ----------------------------------------------------
    # Calibre Library Check (Improved with DB context)
    # ----------------------------------------------------

    # Check for legacy configuration data first, as it contains the source of truth
    if [[ -d "$LEGACY_CONFIG_DIR" ]] && [[ -f "${LEGACY_CONFIG_DIR}/app.db" ]]; then
        local db_calibre_dir
        db_calibre_dir=$(get_db_calibre_dir "${LEGACY_CONFIG_DIR}/app.db")
        if [[ -n "$db_calibre_dir" ]] && [[ "$db_calibre_dir" != "$LEGACY_CALIBRE_LIB_DIR" ]]; then
            print_debug "DB check: App previously set library path to: ${db_calibre_dir}"
            print_debug "NOTE: Installer will only attempt to move the hardcoded legacy default: $LEGACY_CALIBRE_LIB_DIR"
        fi
    fi

    # Check for actual existence of legacy components AND if they need to be moved
    if [[ -d "$LEGACY_INSTALL_DIR" ]] && [[ -f "${LEGACY_INSTALL_DIR}/cps/__init__.py" ]] &&
        [[ "$migrate_app_source" == "true" ]]; then
        print_warning "Found existing Docker-style application at ${YELLOW}${LEGACY_INSTALL_DIR}${RESET}"
        migrate_components+=("app_source")
        needs_migration=true
    fi

    local table_count

    if [[ -d "$LEGACY_CONFIG_DIR" ]] && [[ -f "${LEGACY_CONFIG_DIR}/app.db" ]] &&
        [[ -s "$LEGACY_CONFIG_DIR/app.db" ]] && [[ "$migrate_config_data" == "true" ]]; then
        table_count=$(sqlite3 "$LEGACY_CONFIG_DIR/app.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
        print_debug "SQLite table count: $table_count"
        if [ "$table_count" -gt 5 ]; then # Heuristic to check for actual user data
            print_warning "Found existing Docker-style configuration with user data at ${YELLOW}${LEGACY_CONFIG_DIR}${RESET}"
            migrate_components+=("config_data")
            needs_migration=true
        fi
    fi

    # Migration for the Calibre library is triggered if the old hardcoded default exists
    # AND it contains metadata.db, AND the target path is different.
    if [[ -d "$LEGACY_CALIBRE_LIB_DIR" ]] && [[ -f "${LEGACY_CALIBRE_LIB_DIR}/metadata.db" ]] &&
        [[ "$migrate_calibre_library" == "true" ]]; then
        print_warning "Found existing Calibre library at ${YELLOW}${LEGACY_CALIBRE_LIB_DIR}${RESET}"
        migrate_components+=("calibre_library")
        needs_migration=true
    fi

    # Check for existing systemd services (this is a general update check, not just migration)
    if systemctl is-enabled --quiet autocaliweb.service; then
        EXISTING_INSTALLATION=true # Flag indicates a general update scenario
        print_status "Existing systemd service 'autocaliweb.service' detected."
    fi

    # Handle migration if 'needs_migration' is true
    if [[ "$needs_migration" == "true" ]]; then
        print_warning "Migration required from Docker-style paths to native installation paths."
        print_warning "If you want to keep some of these paths, exit the installer and add
        the required path as an argument (run the script with --help for more information):
        ex: ${GREEN}--library-dir $LEGACY_CALIBRE_LIB_DIR${RESET}"
        echo

        print_status "Summary of changes required:"
        print_status "${BOLD}Old Paths Detected:${RESET}"
        [[ " ${migrate_components[*]} " =~ " app_source " ]] && print_status "  Application:      ${YELLOW}${LEGACY_INSTALL_DIR}${RESET}"
        [[ " ${migrate_components[*]} " =~ " config_data " ]] && print_status "  Configuration:    ${YELLOW}${LEGACY_CONFIG_DIR}${RESET}"
        [[ " ${migrate_components[*]} " =~ " calibre_library " ]] && print_status "  Calibre Library:  ${YELLOW}${LEGACY_CALIBRE_LIB_DIR}${RESET}"

        print_status "${BOLD}New Target Paths:${RESET}"
        print_status "  Application:      ${GREEN}$INSTALL_DIR${RESET}"
        print_status "  Configuration:    ${GREEN}$CONFIG_DIR${RESET}"
        print_status "  Calibre Library:  ${GREEN}$CALIBRE_LIB_DIR${RESET}"
        echo

        # --- DISK SPACE CHECK FOR MIGRATION ---
        local dirs_to_measure=()
        local required_for_migration_mb
        local target_filesystems_raw=() # To collect all target paths (may have duplicates)
        if [[ " ${migrate_components[*]} " =~ " app_source " ]]; then
            dirs_to_measure+=("$LEGACY_INSTALL_DIR")
            target_filesystems_raw+=("$INSTALL_DIR")
        fi
        if [[ " ${migrate_components[*]} " =~ " config_data " ]]; then
            dirs_to_measure+=("$LEGACY_CONFIG_DIR")
            target_filesystems_raw+=("$CONFIG_DIR")
        fi
        if [[ " ${migrate_components[*]} " =~ " calibre_library " ]]; then
            dirs_to_measure+=("$LEGACY_CALIBRE_LIB_DIR")
            target_filesystems_raw+=("$CALIBRE_LIB_DIR")
        fi

        local total_legacy_size_mb
        if [ ${#dirs_to_measure[@]} -gt 0 ]; then
            total_legacy_size_mb=$(get_total_directory_size_mb "${dirs_to_measure[@]}")
            # We are copying, so we need space for the new copy. Add a buffer for safety (20%).
            required_for_migration_mb=$((total_legacy_size_mb * 120 / 100))

            print_status "Total estimated size of data to migrate: ${total_legacy_size_mb} MB (includes ${#migrate_components[@]} components)."
            print_verbose "Required disk space for migration: ${required_for_migration_mb} MB (20% buffer included)."

            local fs_mount_point
            # Identify and check disk space for each *unique* target filesystem
            local unique_target_mount_points=()
            for fs_path in "${target_filesystems_raw[@]}"; do

                local check_path="$fs_path"

                # Safely find the nearest existing parent directory (up to root)
                while [[ ! -d "$check_path" ]]; do
                    if [[ "$check_path" == "/" ]]; then
                        break # Stop at root
                    fi
                    check_path=$(dirname "$check_path")
                done

                fs_mount_point=""
                # Only try to get mount point if we found a valid directory
                if [[ -d "$check_path" ]]; then
                    # Use a subshell protected by '|| true' to ensure set -e is not triggered
                    fs_mount_point=$({ df -P "$check_path" 2>/dev/null | awk 'NR==2 {print $6}'; } || true)
                fi

                # Check if this mount point is already in our unique list
                local found=false
                for unique_mp in "${unique_target_mount_points[@]}"; do
                    if [[ "$unique_mp" == "$fs_mount_point" ]]; then
                        found=true
                        break
                    fi
                done
                # If it's a new unique mount point, add it to the list
                if [ "$found" = false ] && [ -n "$fs_mount_point" ]; then # Ensure mount point is not empty
                    unique_target_mount_points+=("$fs_mount_point")
                fi
            done
            print_debug "Unique target mount points to check: ${unique_target_mount_points[*]}"
            # Finally, perform the disk space check for each unique target filesystem
            print_status "Checking available disk space on target filesystems..."
            for fs_mount_point in "${unique_target_mount_points[@]}"; do
                check_disk_space "$required_for_migration_mb" "$fs_mount_point" "Migration target filesystem"
            done
        fi
        # --- END DISK SPACE CHECK ---

        print_warning "It is highly recommended to create a full backup before starting."
        print_status "You can back up with: ${CYAN}tar -czf acw_backup_$(date +%Y%m%d).tar.gz $LEGACY_INSTALL_DIR $LEGACY_CONFIG_DIR${RESET}"

        if [[ "$ACCEPT_ALL" != "1" ]]; then
            print_prompt "Do you want to migrate the existing components to the new paths? (y/n)" REPLY
            if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                print_error "Migration cancelled by user."
                exit 1
            fi
        fi

        # Pass the array of components to migrate
        migrate_existing_installation "${migrate_components[@]}"

        # After successful migration, consider it an "existing installation" for further update steps
        EXISTING_INSTALLATION=true
    fi

    # Handle general update if EXISTING_INSTALLATION is true (and no migration happened, or migration just completed)
    if [ "$EXISTING_INSTALLATION" = true ] && [ "$needs_migration" = false ]; then
        print_warning "This appears to be an update of an existing installation (no migration needed)."
        print_status "User data and configuration will be preserved."
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-accepting update (--yes flag provided)."
            REPLY="y"
        else
            print_prompt "Continue with update? (y/n)" REPLY "true"
        fi
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            print_error "Update cancelled by user."
            exit 1
        fi
    fi
}

start_acw_services() {
    systemctl start autocaliweb
    if systemctl is-active --quiet autocaliweb; then
        print_status "autocaliweb service started"
    fi
    if [ -f "${INSTALL_DIR}/scripts/ingest_watcher.sh" ]; then
        systemctl start acw-ingest-service
        if systemctl is-active --quiet acw-ingest-service; then
            print_status "acw-ingest-service service started"
        fi
    fi
    if [ -f "${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh" ]; then
        systemctl start acw-auto-zipper
        if systemctl is-active --quiet acw-auto-zipper; then
            print_status "acw-auto-zipper service started"
        fi
    fi
    if [ -f "${INSTALL_DIR}/scripts/cover_enforcer.py" ]; then
        systemctl start metadata-change-detector
        if systemctl is-active --quiet metadata-change-detector; then
            print_status "metadata-change-detector service started"
        fi
    fi
}

stop_acw_services() {
    if [ "$EXISTING_INSTALLATION" = true ]; then
        print_status "Stopping and disabling all existing Autocaliweb services..."
        systemctl stop autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector 2>/dev/null || true
        # Mandatory step to prevent systemd from restarting services during reconfiguration
        sudo systemctl disable autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector >/dev/null 2>&1 || true

        print_status "Services stopped"
    fi
}

restart_acw_services() {
    if [ "$EXISTING_INSTALLATION" = true ]; then
        print_status "Restarting services after update..."
        systemctl daemon-reload
        systemctl restart autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector 2>/dev/null || true
        print_status "Services restarted"
    else
        start_acw_services
    fi
}

git_exclude_file_path() {
    local GIT_EXCLUDE_FILE
    local git_info_dir
    GIT_EXCLUDE_FILE="$INSTALL_DIR/.git/info/exclude"
    git_info_dir="$INSTALL_DIR/.git/info"

    if [ ! -d "$git_info_dir" ]; then
        print_warning "'.git/info' directory not found in $INSTALL_DIR. Cannot add exclusions."
        return 1
    fi

    print_status "Adding application-specific exclusions to Git's local exclude list..."

    # Ensure the file exists
    touch "$GIT_EXCLUDE_FILE"

    # Define all patterns in an array.
    local patterns=(
        "scripts/manual_install_acw.sh"
        "ACW_RELEASE"
        "KEPUBIFY_RELEASE"
        "CALIBRE_RELEASE"
        "acw_update_notice"
        "/config"
        "/metadata_temp"
        "/metadata_change_logs"
        "/.venv"
    )

    local new_exclusions=0

    for pattern in "${patterns[@]}"; do
        # Check if pattern exists.
        if ! grep -qx "$pattern" "$GIT_EXCLUDE_FILE"; then
            echo "$pattern" >>"$GIT_EXCLUDE_FILE"
            # FIX: Under set -e or specific compatibility modes the concise arithmetic increment
            # ((variable++)) can return a non-zero exit code, causing the script to halt immediately.
            # switching to the explicit and more portable form variable=$((variable+1)).
            new_exclusions=$((new_exclusions + 1))
        fi
    done

    if [ "$new_exclusions" -gt 0 ]; then
        print_status "Added $new_exclusions new exclusion(s) to $GIT_EXCLUDE_FILE."
    else
        print_status "All application exclusions already present in local exclude list."
    fi

    # Handle tracked files (like dirs.json) automatically
    if [ -f "$INSTALL_DIR/dirs.json" ]; then
        # Check if the file is tracked by git
        if git -C "$INSTALL_DIR" ls-files --error-unmatch dirs.json >/dev/null 2>&1; then
            # It is tracked, so we assume-unchanged
            git -C "$INSTALL_DIR" update-index --assume-unchanged dirs.json
            print_verbose "Marked dirs.json as assume-unchanged."
        fi
    fi
}

# Helper function for git repository detection
check_if_git_repo() {
    local dir="$1"
    local candidates=()

    # Determine the user to perform the git check as.
    # 1. Legacy service user (always considered)
    candidates+=("${LEGACY_SERVICE_USER:-abc}")
    # 2. Owner of legacy install dir (if available)
    if [[ "$IS_LEGACY_MIGRATION" == "true" && -d "$LEGACY_INSTALL_DIR" ]]; then
        local owner
        owner=$(stat -c '%U' "$LEGACY_INSTALL_DIR" 2>/dev/null || true)
        [[ -n "$owner" ]] && candidates+=("$owner")
    fi
    # 3. Root
    candidates+=("root")
    # 4. Current service user
    candidates+=("$SERVICE_USER")
    # 5. Real user
    candidates+=("$REAL_USER")
    # Deduplicate candidates while preserving order
    # use mapfile to avoid break if a candidate username has spaces (unlikely, but possible).
    mapfile -t candidates < <(printf "%s\n" "${candidates[@]}" | awk '!seen[$0]++')
    # Try each candidate until one succeeds
    for user in "${candidates[@]}"; do
        print_verbose "Trying git check with user '$user'..."
        if su -s /bin/bash -c "git -C \"$INSTALL_DIR\" rev-parse --is-inside-work-tree >/dev/null 2>&1" "$user"; then
            GIT_CHECK_USER="$user"
            print_status "Git repo check succeeded with user: $GIT_CHECK_USER"
            is_git_repo=true
            git_exclude_file_path
            break
        else
            print_verbose "Git check failed for user '$user'"
            GIT_CHECK_USER=""
        fi
    done

    if [[ -z "$GIT_CHECK_USER" ]]; then
        print_warning "No suitable user could access git repo. Assuming not a git checkout."
    fi

    # TODO: check if we need the echo or just the global variable only
    #echo "$GIT_CHECK_USER" # Return the Git User or empty string (not git)
}

backup_existing_data() {
    backup_files \
        "$CONFIG_DIR/app.db" \
        "$CONFIG_DIR/acw.db" \
        "$CALIBRE_LIB_DIR/metadata.db" \
        "$CALIBRE_LIB_DIR/.calnotes/notes.db"
}

# ==================================================================
# FIX: Added 'shopt -s nullglob' to prevent non-matching wildcards
# from causing 'rm' to fail when set -e is active.
# ==================================================================
# Cleanup like root/etc/s6-overlay/s6-rc.d/acw-init/run
cleanup_lock_files() {
    if [ "$EXISTING_INSTALLATION" = true ]; then
        print_status "Checking for leftover lock files..."
        local counter=0
        # Define specific known lock files (with full path)
        local files_to_check=(
            "/tmp/ingest_processor.lock"
            "/tmp/convert_library.lock"
            "/tmp/cover_enforcer.lock"
            "/tmp/kindle_epub_fixer.lock"
        )

        # --- FIX: Temporarily enable nullglob ---
        # If no files match the wildcard, it expands to an empty list,
        # preventing the literal "/tmp/uv-*.lock" from being added.
        # --- FIX2: shopt will fail if OPTNAME is disabled, added ||.
        local old_nullglob
        set +e
        old_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob") # Save current setting
        set -e

        # Append the wildcard matches to the array
        # IMPORTANT: No quotes around the wildcard below.
        files_to_check+=(/tmp/uv-*.lock)

        # Restore nullglob setting immediately after globbing, ignor return value.
        set +e
        eval "$old_nullglob"
        set -e
        # --- End FIX ---

        # Loop through the resulting list
        for f in "${files_to_check[@]}"; do
            # The -f check protects us if the wildcard found nothing
            # (in which case the literal string remains but -f returns false)
            if [ -f "$f" ]; then
                print_verbose "Removing leftover $(basename "$f")..."
                # We use rm and rely on set -e. If rm fails (e.g., permission denied),
                # the script will exit here.
                # FIX: Use '|| true' to suppress the non-zero exit code
                rm -f "$f" || true
                # Check if the file was successfully removed before incrementing the counter.
                # Fix: The arithmetic command ((counter++)) can return a non-zero exit code under some shell environments.
                if [ ! -f "$f" ]; then
                    counter=$((counter + 1))
                else
                    # Print a warning if removal failed but file still exists.
                    echo "three"
                    print_verbose "WARNING: Failed to remove lock file $(basename "$f"). Permission issue or file actively held."
                    echo "four"
                fi
            fi
        done

        print_status "$counter lock file(s) removed."
    fi
}

# =============================
# Global Package Definitions
# =============================
# # SC2178 : cannot assign list to array member :(
# # --- Global Package Lists (per distro) ---
# declare -A PKG_COMMON
# declare -A PKG_GRAPHICS_HEADLESS
# declare -A PKG_GRAPHICS_DESKTOP
# # V.3.7.0 Fix: group pcakges based on OS / Distro not package manager.
#           replace PKG_COMMON_[package manager] with PKG_COMMON_[distro] ..etc

# --- Debian / Ubuntu ---
PKG_COMMON_UBUNTU=(
    # Python dependencies
    python3-dev python3-pip python3-venv
    # Build tools
    build-essential libldap2-dev libssl-dev libsasl2-dev
    # Image/PDF
    imagemagick ghostscript
    # Utilities
    sqlite3 xdg-utils inotify-tools
    netcat-openbsd binutils curl wget git
    tzdata zip xz-utils
)
PKG_GRAPHICS_HEADLESS_UBUNTU=(
    libmagic1 libnss3 libegl1 libgl1 libxdamage1 libxkbcommon0
)
PKG_GRAPHICS_DESKTOP_UBUNTU=(
    libmagic1 libxi6 libxslt1.1 libxtst6 libxrandr2 libxkbfile1
    libxcomposite1 libopengl0 libnss3 libxkbcommon0 libegl1
    libxdamage1 libgl1 libglx-mesa0
)

# --- Fedora ---
# V.3.6.1 FIX: Replace "@Development Tools" with @development-tools
#              removed: 'libmagic' and 'mozilla-nss'
# V.3.6.2 FIX: Using the DNF group ID to install the full C/Build environment
#               Added: file-devel & nss-devel  to cover 'libmagic' and 'mozilla-nss' removal
# V.3.6.3 FIX: Added specific C++ compiler package to ensure 'g++' is found for packages like faust-cchardet.
# V.3.7.0 Fix: Separate Fedora from RHEL / CentOS to solve package names conflict
#       remove mesa-libGLX
PKG_COMMON_FEDORA=(
    python3-devel python3-pip python3-virtualenv
    @development-tools openldap-devel openssl-devel cyrus-sasl-devel
    ImageMagick ghostscript sqlite3 xdg-utils inotify-tools
    nmap-ncat binutils curl wget git xz
    file-devel nss-devel
    gcc-c++
)
PKG_GRAPHICS_HEADLESS_FEDORA=(
    libEGL libGL libxkbcommon libXdamage
)
# V.3.7.1 Fix: Remove: mesa-libGLX
PKG_GRAPHICS_DESKTOP_FEDORA=(
    libXext libxslt libXtst libXrandr libxkbfile libXcomposite
    libGL libEGL libxkbcommon libXdamage
)

# --- RHEL / CentOS ---
# V.3.7.1 Fix: Remove: file-devel file-libs-devel libmagic-devel python3-virtualenv
PKG_COMMON_CENTOS=(
    python3-devel python3-pip
    openldap-devel openssl-devel cyrus-sasl-devel
    ImageMagick ghostscript
    sqlite3 xdg-utils inotify-tools
    nmap-ncat binutils curl wget git xz
    nss-devel # Added to cover 'libmagic' and 'mozilla-nss' errors
    @'Development Tools'
)
# V.3.7.1 Fix: typo: libxkbcommon-devel not libxkb common-devel
PKG_GRAPHICS_HEADLESS_CENTOS=(
    mesa-libGL-devel libglvnd-devel libxkbcommon-devel libXdamage-devel
    mesa-libEGL-devel # Added explicit EGL development package
)
PKG_GRAPHICS_DESKTOP_CENTOS=(
    libXext-devel libXrender-devel libXtst-devel libXrandr-devel libXcomposite-devel #libxkbfile-devel
    libXi-devel
    mesa-libGL-devel libglvnd-devel libxkbcommon-devel libXdamage-devel
    mesa-libEGL-devel
)

# RHEL uses CentOS list.
# For future use if we have different packages between RHEL and CentOS.
# PKG_COMMON_RHEL=("${PKG_COMMON_CENTOS[@]}")
# PKG_GRAPHICS_HEADLESS_RHEL=("${PKG_GRAPHICS_HEADLESS_CENTOS[@]}")
# PKG_GRAPHICS_DESKTOP_RHEL=("${PKG_GRAPHICS_DESKTOP_CENTOS[@]}")

# --- Arch Linux ---
PKG_COMMON_ARCH=(
    python python-pip python-virtualenv
    base-devel openldap openssl cyrus-sasl
    imagemagick ghostscript sqlite inotify-tools
    openbsd-netcat binutils curl wget git xz
)
# V.3.6.3 FIX: Remove libmagic to fix target not found
PKG_GRAPHICS_HEADLESS_ARCH=(
    nss libegl libgl libxkbcommon libxdamage mesa
)
PKG_GRAPHICS_DESKTOP_ARCH=(
    # libmagic libegl
    libxext libxslt libxtst libxrandr libxkbfile libxcomposite
    libgl libxkbcommon libxdamage mesa
)

# === openSUSE Family ===
# Python packages for openSUSE needs a version prefix (e.g., python313-devel).
# Keep them generic here, and we'll append the version in a dedicated function.
# python3-virtualenv (sometimes unversioned) to be tested.
PKG_COMMON_OPENSUSE_PYTHON=(
    python3-devel python3-pip python3-virtualenv
)

# Fix1: patterns-devel-base --> patterns devel_basis
# Fix2: pattern should install separtly with -t argument
# Fix3: add cyrus-sasl we need SASL plugins to prevent:
#       looking for plugins in '/usr/lib64/sasl2', failed to open directory, error: No such file or directory
# --- openSUSE Leap ---
PKG_COMMON_OPENSUSE_LEAP=(
    # gcc make
    openldap2-devel libopenssl-devel cyrus-sasl cyrus-sasl-devel
    ImageMagick ghostscript sqlite3 xdg-utils inotify-tools
    netcat-openbsd binutils curl wget git timezone zip xz
)
# V.3.7.1 Fix: Remove libEGL1 libGL1
PKG_GRAPHICS_HEADLESS_OPENSUSE_LEAP=(
    libmagic1 mozilla-nss libxkbcommon0 libXdamage1
)
# V.3.7.1 Fix: Remove Mesa-libGLX1 libEGL1
PKG_GRAPHICS_DESKTOP_OPENSUSE_LEAP=(
    libmagic1 libXi6 libxslt1 libXtst6 libXrandr2 libxkbfile1 libXcomposite1
    libglvnd libEGL1 libXdamage1 Mesa-libGL1 # check if Mesa-libGLX1  exsists in leap & SLES
)

# --- openSUSE Tumbleweed ---
PKG_COMMON_OPENSUSE_TW=(
    gcc make openldap2-devel libopenssl-devel cyrus-sasl-devel
    ImageMagick ghostscript sqlite3 xdg-utils inotify-tools
    netcat-openbsd binutils curl wget git timezone zip xz
)
PKG_GRAPHICS_HEADLESS_OPENSUSE_TW=(
    libmagic1 mozilla-nss libxkbcommon0 libXdamage1 Mesa-libEGL1
    Mesa-libGLESv2-devel Mesa-libGL1 Mesa-dri
)
# PKG_GRAPHICS_HEADLESS_OPENSUSE_TW=(libmagic1 mozilla-nss libxkbcommon0 libXdamage1)
# PKG_GRAPHICS_DESKTOP_OPENSUSE_TW=( libmagic1 libXi6 libxslt1 libXtst6 libXrandr2 libxkbfile1 libXcomposite1 libglvnd libEGL1 libXdamage1 Mesa-libGL1 )

PKG_GRAPHICS_DESKTOP_OPENSUSE_TW=(
    # Core X Dependencies
    libXi6 libXtst6 libXrandr2 libxkbfile1 libXcomposite1 libXdamage1
    libXcursor1 libXft2 libXext6 libXxf86vm1
    # Core GL/Vulkan Stack
    libglvnd Mesa-libEGL1 Mesa-libGL1 Mesa-libGLESv2-devel libvulkan1 Mesa-dri
    # General Dependencies
    libmagic1 libxslt1
)

# V.3.7.1 Fix: remove python family use common one & Mesa-libGL1 instead of libGL1
# --- SLES ---
PKG_COMMON_SLES=(
    gcc make openldap2-devel libopenssl-devel cyrus-sasl-devel
    ImageMagick ghostscript sqlite3 xdg-utils inotify-tools
    netcat-openbsd binutils curl wget git timezone zip xz
)
PKG_GRAPHICS_HEADLESS_SLES=(libmagic1 mozilla-nss libEGL1 libxkbcommon0 libXdamage1)
PKG_GRAPHICS_DESKTOP_SLES=(libmagic1 libXi6 libxslt1 libXtst6 libXrandr2 libxkbfile1 libXcomposite1 libglvnd libEGL1 libXdamage1 Mesa-libGL1 Mesa-libGLX1)
# =======================

# V.3.7.0 Alpine linux removed: no systemd
# TODO: use systemctl-alpine (still beta) or similar tools to translate
#       systemd commands to their OpenRC equivalents or remove Alpine.
# # --- Alpine Linux ---
# PKG_COMMON_APK=(
#    python3-dev py3-pip py3-virtualenv
#    build-base openldap-dev openssl-dev cyrus-sasl-dev
#    imagemagick ghostscript sqlite xdg-utils inotify-tools
#    netcat-openbsd binutils curl wget git tzdata zip xz
#)
# PKG_GRAPHICS_HEADLESS_APK=(
#    file nss libegl-dev libgl-dev libxkbcommon-dev libxdamage-dev mesa-gl
#)
# PKG_GRAPHICS_DESKTOP_APK=(
#    file libxi-dev libxslt-dev libxtst-dev libxrandr-dev libxkbfile-dev
#    libxcomposite-dev libgl-dev nss libxkbcommon-dev libegl-dev
#    libxdamage-dev mesa-gl mesa-glx
#)

# ==============================================================================
# openSUSE Helper Functions (New)
# ==============================================================================
# get_opensuse_versioned_packages - Transforms generic python package names
# into openSUSE versioned names (e.g., python3-devel -> python313-devel).
# Returns: Array of versioned package names printed to stdout.
get_opensuse_versioned_packages() {
    local python_version_no_dot=${PYTHON_VERSION//./}
    local versioned_packages=()

    for package in "${PKG_COMMON_OPENSUSE_PYTHON[@]}"; do
        # Check if the package name starts with "python3-"
        if [[ "$package" == "python3-"* ]]; then
            # Replace "python3-" with "python3XX-"
            versioned_packages+=("${package/python3-/python${python_version_no_dot}-}")
        else
            # Fallback (though all in this array should match)
            versioned_packages+=("$package")
        fi
    done

    # Print the resulting array elements, separated by spaces, for command substitution
    echo "${versioned_packages[@]}"
}

# install_opensuse_patterns_and_repos - Installs the necessary development pattern
# and handles the repository fallback logic specific to OpenSUSE/SLES.
install_opensuse_patterns_and_repos() {
    print_status "Attempting to install 'devel_basis' pattern..."

    if ! sudo zypper install -t pattern devel_basis >/dev/null 2>&1; then
        print_warning "'devel_basis' pattern installation failed. Checking for missing development repository."

        # Check if the 'openSUSE:Factory' repository is already configured
        if ! sudo zypper lr | grep -q "openSUSE:Factory"; then
            print_status "Adding openSUSE:Factory repository for development packages..."

            # Attempt to add Factory repo
            sudo zypper ar -G --refresh http://download.opensuse.org/factory/repo/oss/ openSUSE:Factory ||
                print_warning "Failed to add Factory repository. Retrying with Leap alias."

            # Fallback for Leap distribution if Factory failed
            if ! sudo zypper lr | grep -q "openSUSE:Factory"; then
                # $releasever is a zypper variable for the current major OS version
                #shellcheck disable=SC2154
                sudo zypper ar -G --refresh http://download.opensuse.org/distribution/leap/"$releasever"/repo/oss/ openSUSE:Development ||
                    print_error "Failed to add any development repository. Package installation may fail."
            fi
        fi

        print_status "Retrying 'devel_basis' pattern installation after adding development repositories..."
        if ! sudo zypper install -t pattern devel_basis >/dev/null 2>&1; then
            print_warning "Pattern installation failed even after adding development repos. Continuing with main packages."
            return 1 # Return failure, but don't exit the script yet
        fi
    fi

    print_status "'devel_basis' pattern installed successfully."
    return 0
}

# Install system or core dependencies
# Arguments:
#    $@: optional list of specific packages to install
install_system_deps() {

    # Make sure package manager is detected
    if [[ -z "$PKG_MANAGER" ]]; then
        detect_distro_and_package_manager || {
            print_error "Could not detect a supported package manager. Aborting."
            exit 1
        }
    fi

    local packages_to_install=()
    local PKG_COMMON=()
    local PKG_GRAPHICS_HEADLESS=()
    local PKG_GRAPHICS_DESKTOP=()
    local pkg_output
    if [[ "$VERBOSE" = "1" || "$DEBUG_MODE" = "1" ]]; then
        pkg_output="/dev/stdout"
    else
        pkg_output="/dev/null"
    fi
    # --- 1. Populate packages_to_install array ---
    # If arguments are provided, install only those specific packages.
    # This is for the core dependencies needed to run the script itself.
    if [ "$#" -gt 0 ]; then
        packages_to_install=("$@")
        print_status "Installing specific core dependencies: ${packages_to_install[*]}"
    else
        # If no arguments, determine the full dependency list based on the distro
        case "$DISTRO_FAMILY" in
            ubuntu | debian)
                PKG_COMMON=("${PKG_COMMON_UBUNTU[@]}")
                PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_UBUNTU[@]}")
                PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_UBUNTU[@]}")
                ;;
            fedora)
                PKG_COMMON=("${PKG_COMMON_FEDORA[@]}")
                PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_FEDORA[@]}")
                PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_FEDORA[@]}")
                ;;
            centos | rhel)
                PKG_COMMON=("${PKG_COMMON_CENTOS[@]}")
                PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_CENTOS[@]}")
                PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_CENTOS[@]}")
                ;;
            arch)
                PKG_COMMON=("${PKG_COMMON_ARCH[@]}")
                PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_ARCH[@]}")
                PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_ARCH[@]}")
                ;;
            # openSUSE family needs patterns to install separatly & versioned python packages
            opensuse-leap)
                # 1. Install patterns and handle repo fallbacks first
                install_opensuse_patterns_and_repos
                # 2. Get the versioned Python packages
                read -r -a python_pkgs <<<"$(get_opensuse_versioned_packages)"
                PKG_COMMON=("${python_pkgs[@]}")
                # 3. Add common and set graphics packages
                PKG_COMMON+=("${PKG_COMMON_OPENSUSE_LEAP[@]}")
                PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_OPENSUSE_LEAP[@]}")
                PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_OPENSUSE_LEAP[@]}")
                ;;
            opensuse-tumbleweed)
                # 1. Install patterns and handle repo fallbacks first
                install_opensuse_patterns_and_repos
                # 2. Get the versioned Python packages
                read -r -a python_pkgs <<<"$(get_opensuse_versioned_packages)"
                PKG_COMMON=("${python_pkgs[@]}")
                # 3. Add common and set graphics packages
                PKG_COMMON+=("${PKG_COMMON_OPENSUSE_TW[@]}")
                PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_OPENSUSE_TW[@]}")
                PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_OPENSUSE_TW[@]}")
                ;;
            sles)
                # 1. Install patterns and handle repo fallbacks first
                install_opensuse_patterns_and_repos
                # 2. Get the versioned Python packages
                read -r -a python_pkgs <<<"$(get_opensuse_versioned_packages)"
                PKG_COMMON=("${python_pkgs[@]}")
                # 3. Add common and set graphics packages
                PKG_COMMON+=("${PKG_COMMON_SLES[@]}")
                PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_SLES[@]}")
                PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_SLES[@]}")
                ;;
            *)
                print_warning "Unknown distribution family '$DISTRO_FAMILY'. Using generic $PKG_MANAGER package list."
                ;;
        esac

        if [[ "$IS_HEADLESS" = "1" ]]; then
            print_status "Headless environment detected – installing minimal graphics stack."
            packages_to_install=("${PKG_COMMON[@]}" "${PKG_GRAPHICS_HEADLESS[@]}")
        else
            print_status "Desktop environment detected – installing full graphics stack."
            packages_to_install=("${PKG_COMMON[@]}" "${PKG_GRAPHICS_DESKTOP[@]}")
        fi

    fi

    # --- 2. Run installation with the populated package list ---

    # Only run the install command if packages_to_install is not empty
    if [ "${#packages_to_install[@]}" -eq 0 ]; then
        if [ "$#" -eq 0 ]; then
            print_status "No dependencies configured for $PKG_MANAGER in this mode. Skipping installation."
            return 0
        else
            print_error "Attempted to install specific packages, but the list was empty."
            return 1
        fi
    fi

    local base_cmd
    IFS=' ' read -r -a base_cmd <<<"${PKG_INSTALL_ARRAY[$PKG_MANAGER]}"
    local cmd_array=("${base_cmd[@]}" "${packages_to_install[@]}")

    # The error handling for zypper fallbacks is now contained within
    # install_opensuse_patterns_and_repos, so we can simplify the main install logic.
    print_status "Running install command: ${cmd_array[*]}"

    # Reset trap and allow non-zero exit code just for the install command
    set +e

    if ! "${cmd_array[@]}" 2>&1 | tee -a "$LOG_FILE" >"$pkg_output"; then
        print_error "Failed to install dependencies with $PKG_MANAGER."
        print_error "Installation aborted. Check $LOG_FILE for details. Retry manually with:"
        echo "    ${cmd_array[*]}" >&2
        set -e # Re-enable set -e
        return 1
    fi
    set -e # Re-enable set -e

    print_status "Dependencies installed successfully."
    set -e
    return 0
}

# Helper function to compare versions (v1 < v2)
# Returns 0 if v1 is strictly less than v2, 1 otherwise
version_lt() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ] && [ "$1" != "$2" ]
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    local attempt=1

    # Build curl options as an array
    # Fix: curl: option -sS -L --connect-timeout 30 --max-time 300: is unknown
    local curl_opts
    curl_opts=(-L --connect-timeout 30 --max-time 300)
    if [ "$VERBOSE" = "0" ]; then
        curl_opts=(-sS "${curl_opts[@]}")
    fi
    while [ $attempt -le $max_attempts ]; do
        print_status "Download attempt $attempt/$max_attempts..."
        if curl "${curl_opts[@]}" -o "$output" "$url"; then
            print_status "Download successful: $output"
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            print_warning "Download failed, retrying in 5 seconds..."
            sleep 5
        fi
    done
    print_error "Failed to download after $max_attempts attempts"
    return 1
}

# Encapsulate download and extraction logic
download_and_extract_autocaliweb_source() {
    local AUTOCALIWEB_RELEASE
    AUTOCALIWEB_RELEASE=$(curl -s https://api.github.com/repos/gelbphoenix/autocaliweb/releases/latest |
        grep -o '"tag_name": "[^"]*' |
        cut -d'"' -f4)

    if [ -z "$AUTOCALIWEB_RELEASE" ]; then
        print_error "Failed to retrieve latest Autocaliweb release tag. Aborting source download."
        exit 1
    fi

    local tarball_url="https://github.com/gelbphoenix/autocaliweb/archive/refs/tags/${AUTOCALIWEB_RELEASE}.tar.gz"
    local tarball_file="/tmp/autocaliweb-${AUTOCALIWEB_RELEASE}.tar.gz"

    # Avoid download keep the source at /tmp, ex: autocaliweb-v0.10.2.tar.gz (with 'v')
    if [ ! -f "/tmp/autocaliweb-${AUTOCALIWEB_RELEASE}.tar.gz" ]; then
        print_status "Downloading Autocaliweb $AUTOCALIWEB_RELEASE..."
        if ! download_with_retry "$tarball_url" "$tarball_file"; then
            print_error "Failed to download Autocaliweb source after multiple attempts. Aborting."
            exit 1
        fi
    else
        print_status "Found Autocaliweb $AUTOCALIWEB_RELEASE at /tmp/autocaliweb-${AUTOCALIWEB_RELEASE}.tar.gz"
    fi

    print_status "Cleaning existing Autocaliweb source in $INSTALL_DIR before extraction (preserving user data, logs, and configuration directories)..."

    # Define files/directories that should be cleaned up during installation
    local CLEANUP_ITEMS=(
        "cps"
        "requirements.txt"
        "optional-requirements.txt"
        "uv.lock"
        "pyproject.toml"
        "MANIFEST.in"
        "Dockerfile"
        "root"
        ".dockerignore"
        "README.md"
        "LICENSE"
        "autocaliweb.egg-info"
    )

    # Clean up only specific items
    for item in "${CLEANUP_ITEMS[@]}"; do
        if [ -e "$INSTALL_DIR/$item" ]; then
            print_verbose "Removing $item..."
            rm -rf "${INSTALL_DIR:?}/$item" >/dev/null 2>&1
        fi
    done

    if ! tar xf "$tarball_file" -C "$INSTALL_DIR" --strip-components=1; then
        print_error "Failed to extract Autocaliweb source. Aborting."
        rm -f "$tarball_file"
        exit 1
    fi

    rm -f "$tarball_file"

    sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

    print_status "Autocaliweb source downloaded and extracted successfully."
}

check_directories() {
    local current_scenario="$1"
    local CURRENT_ACW_VERSION
    local LATEST_ACW_RELEASE
    print_status "Checking directory structure..."

    # Check if main directories exist
    if [ ! -d "$INSTALL_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
        print_error "Required directories not found."
        exit 1
    fi

    # --- SCENARIO: No Source ---
    if [ "$current_scenario" == "no_source" ]; then
        print_status "Autocaliweb source not found. Downloading latest release..."
        download_and_extract_autocaliweb_source

    # --- SCENARIO: Local Copy ---
    elif [ "$current_scenario" == "outside_without_template" ]; then
        print_status "Copying Autocaliweb source from: $SCRIPT_SOURCE_DIR..."
        rsync -a "$SCRIPT_SOURCE_DIR/" "$INSTALL_DIR/"
        chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

        if rsync -a "$SCRIPT_SOURCE_DIR/" "$INSTALL_DIR/" 2>&1; then
            print_verbose "Setting ownership on $INSTALL_DIR..."
            # This is CRITICAL to prevent permission denied errors for the service user
            chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
            print_status "Application source copied successfully."
        else
            print_error "Failed to copy application source."
            exit 1
        fi

    # --- SCENARIO: Existing Source ---
    else
        # Handle Git Repositories
        if [[ "$current_scenario" =~ "git_repo" ]]; then
            if [[ -z "$GIT_CHECK_USER" ]]; then git_user="$SERVICE_USER"; else git_user="${GIT_CHECK_USER}"; fi
            # --- FIX: HANDLE DUBIOUS OWNERSHIP ---
            # If the user is not the owner of the Git repo, Git security features will block operations.
            # We fix this by adding the directory to the user's global safe list.
            print_verbose "Ensuring Git repository is marked as safe for user '$git_user'..."

            # This must be run by the current process user (which has sudo rights) on behalf of $git_user
            su -s /bin/bash -c "git config --global --add safe.directory \"$INSTALL_DIR\"" "$git_user" || true
            # We use '|| true' to suppress fatal error exit if git fails, though it should succeed here.

            # --- FIX: IGNORE PERMISSION CHANGES ---
            # This prevents the loop where 644 vs 755 keeps marking the repo as "dirty"

            # FIX 1: Use 'git -C "$INSTALL_DIR"' instead of 'cd && git' for robustness.
            # FIX 2: Add '|| true' to suppress fatal error exit if git fails unexpectedly.
            su -s /bin/bash -c "git -C \"$INSTALL_DIR\" config core.fileMode false" "$git_user" || true

            if [ "$ACCEPT_ALL" = "1" ]; then
                print_status "Auto-accepting git update (--yes flag provided)"
                USER_CONFIRMATION="y"
            else
                print_prompt "Git repository detected. Do you want to check for updates? (y/n)" USER_CONFIRMATION "true"
            fi

            if [[ "$USER_CONFIRMATION" =~ ^[Yy]$ ]]; then
                print_status "Checking for updates..."

                # Temporarily disable exit-on-error to handle the check gracefully
                set +e

                # Check for changes (fetch only, don't merge yet)
                su -s /bin/bash -c "cd \"$INSTALL_DIR\" && git fetch origin main" "$git_user"

                # Check if we are behind (this counts commits)
                LOCAL_HASH=$(su -s /bin/bash -c "cd \"$INSTALL_DIR\" && git rev-parse HEAD" "$git_user")
                REMOTE_HASH=$(su -s /bin/bash -c "cd \"$INSTALL_DIR\" && git rev-parse origin/main" "$git_user")

                if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
                    print_status "Git repository is already up to date."
                    set -e
                else
                    # We are behind (or ahead, or divergent). Check for "dirty" files.
                    # Because we set core.fileMode false above, permissions won't trigger this anymore.
                    if ! su -s /bin/bash -c "cd \"$INSTALL_DIR\" && git diff --quiet" "$git_user"; then
                        # --- DIRTY STATE DETECTED ---
                        print_error "Cannot update: You have local modifications."
                        print_warning "Select an action:"
                        print_option "[S] Stash local changes and update (Preserves your changes)"
                        print_option "[D] Discard local changes and update (Overwrites everything)"
                        print_option "[C] Cancel update (Keep current version)"
                        print_option "[X] Exit installation"

                        # read -p "Enter your choice: " -n 1 -r
                        print_prompt "Enter choice (S/D/C/X)" CHOICE "true"

                        case "$CHOICE" in
                            [Ss]*)
                                print_status "Stashing changes and updating..."
                                su -s /bin/bash -c "cd \"$INSTALL_DIR\" && git stash push -m 'Installer Stash' && git reset --hard origin/main && git stash pop" "$git_user"
                                ;;
                            [Dd]*)
                                print_status "Discarding changes and updating..."
                                su -s /bin/bash -c "cd \"$INSTALL_DIR\" && git reset --hard origin/main" "$git_user"
                                ;;
                            [Cc]*)
                                print_warning "Continuing installation with existing source code."
                                ;;
                            [Xx]*)
                                print_error "Installation aborted by user."
                                exit 1
                                ;;
                            *)
                                print_warning "Invalid choice. Update skipped."
                                ;;
                        esac
                    else
                        # --- CLEAN STATE, JUST UPDATE ---
                        print_status "Updating to latest version..."
                        # use reset --hard instead of pull to avoid "divergent branch" errors
                        su -s /bin/bash -c "cd \"$INSTALL_DIR\" && git reset --hard origin/main" "$git_user"
                        print_status "Update complete."
                    fi
                fi
                set -e
            else
                print_status "Skipping Git repository update."
            fi
        # Not a Git repository, use version-based update logic
        else
            if [ "$ACCEPT_ALL" = "1" ]; then
                print_status "Auto-accepting update (--yes flag provided)"
                REPLY="y"
            else
                print_prompt "Autocaliweb source found. Do you want to check for and apply updates? (y/n)" REPLY "true"
            fi

            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                print_status "Checking for Autocaliweb updates..."
                # Version-based update logic for non-git installations
                if [ -f "$INSTALL_DIR/ACW_RELEASE" ]; then
                    CURRENT_ACW_VERSION=$(cat "$INSTALL_DIR/ACW_RELEASE")
                fi

                LATEST_ACW_RELEASE=$(curl -s https://api.github.com/repos/gelbphoenix/autocaliweb/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
                if [ -z "$LATEST_ACW_RELEASE" ]; then
                    print_error "Failed to retrieve latest Autocaliweb release tag from GitHub. Cannot check for updates."
                    print_warning "Continuing installation with existing source code."
                    # Don't exit, just continue with current source
                elif [ -z "$CURRENT_ACW_VERSION" ] || version_lt "$CURRENT_ACW_VERSION" "$LATEST_ACW_RELEASE"; then
                    print_status "Current version ($CURRENT_ACW_VERSION) is older than or unknown compared to latest release ($LATEST_ACW_RELEASE)."
                    print_status "Re-downloading latest release to update..."
                    download_and_extract_autocaliweb_source
                else
                    print_status "Current version ($CURRENT_ACW_VERSION) is already the latest release ($LATEST_ACW_RELEASE). No re-download needed."
                fi
            else
                print_status "Skipping Autocaliweb source update."
            fi
        fi
    fi

    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR" "$CONFIG_DIR"

    # Verify ownership (still crucial after any source manipulation)
    if [ ! -w "$INSTALL_DIR" ] || [ ! -w "$CONFIG_DIR" ]; then
        print_error "Insufficient permissions for required directories."
        exit 1
    fi
    print_status "Directory structure verified"
}

setup_autocaliweb() {
    print_status "Setting up Autocaliweb..."
    cd "$INSTALL_DIR" || exit 1

    # Verify source code exists
    if [ ! -f "requirements.txt" ] && [ ! -f "uv.lock" ]; then
        print_error "Autocaliweb source not found in $INSTALL_DIR"
        exit 1
    fi

    # Ask about optional dependencies upfront
    local use_optional=false
    if [ -f "optional-requirements.txt" ]; then
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-installing optional dependencies (--yes flag provided)"
            use_optional=true
            FIX_PYTHON_PAC=true
        else
            print_prompt "Do you want to install optional dependencies? (y/n)" USER_CONFIRMATION "true"
            if [[ "$USER_CONFIRMATION" =~ ^[Yy]$ ]]; then
                use_optional=true
                FIX_PYTHON_PAC=true
            fi
        fi
    fi

    # Create .venv if missing
    if [ "$EXISTING_INSTALLATION" = true ] && [ -d ".venv" ]; then
        print_status "Updating existing Python environment..."
    else
        print_status "Creating fresh Python environment..."
        run_with_progress sudo -u "$SERVICE_USER" python3 -m venv .venv
    fi

    # --- Try uv first if lock file exists ---
    local UV_OK=0
    if [ -f "uv.lock" ]; then
        print_status "Detected uv.lock → trying Astral uv for dependency installation"

        # Ensure uv is installed in .venv
        if ! sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/uv" --version >/dev/null 2>&1; then
            print_status "Installing uv (fast Python package manager)..."
            if ! run_with_progress sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" install -U uv; then
                print_warning "Failed to install uv — will fall back to pip-tools later"
            fi
        fi
    fi

    # Fix: failed to create directory `/nonexistent/.cache/uv` → set HOME
    # ~~set HOME AFTER sudo otherwise service user will not see the home~~
    # Now we set home in prepare_service_environment(), since v3.2 No more env HOME.

    # build uv sync command (use array to avoid quoting problems)
    uv_cmd=(sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/uv" --directory "$INSTALL_DIR" sync --locked --no-install-project)

    # If user asked for optional dependencies, add the uv flag:
    if [ "$use_optional" = true ]; then
        uv_cmd+=(--all-extras)
        print_status "Installing extras via uv (--all-extras)"
    fi

    if run_with_progress "${uv_cmd[@]}"; then
        UV_OK=1
    else
        print_warning "uv sync with --locked (and extras) failed. Attempting to regenerate uv.lock and retry..."
        # try to regenerate then sync without locked (same array technique)
        if run_with_progress sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/uv" --directory "$INSTALL_DIR" lock; then
            uv_cmd=(sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/uv" --directory "$INSTALL_DIR" sync --no-install-project)
            if [ "$use_optional" = true ]; then uv_cmd+=(--all-extras); fi
            if run_with_progress "${uv_cmd[@]}"; then
                UV_OK=1
            else
                print_warning "uv sync still failed after regenerating lockfile."
            fi
        else
            print_warning "uv lock regeneration failed."
        fi
    fi

    # --- If uv failed or no uv.lock fallback to pip-tools ---
    if [ "$UV_OK" -eq 0 ]; then
        print_status "Using pip-tools workflow (no usable uv.lock found)..."

        # shellcheck disable=SC1091
        source "$INSTALL_DIR/.venv/bin/activate"

        run_with_progress sudo -u "$SERVICE_USER" \
            "$INSTALL_DIR/.venv/bin/pip" install -U pip wheel pip-tools

        if [ "$use_optional" = true ]; then
            if [ -f "combined-requirements.lock" ]; then
                print_status "Installing core + optional dependencies from lock file..."
                run_with_progress sudo -u "$SERVICE_USER" \
                    "$INSTALL_DIR/.venv/bin/pip-sync" combined-requirements.lock
            else
                print_status "Generating combined requirements on-the-fly..."
                print_status "Please be patient, this process can take several minutes..."
                (
                    cat requirements.txt
                    echo
                    cat optional-requirements.txt
                ) >combined-requirements.txt
                if run_with_progress sudo -u "$SERVICE_USER" \
                    "$INSTALL_DIR/.venv/bin/pip-compile" \
                    --strip-extras combined-requirements.txt --output-file combined-requirements.lock; then
                    run_with_progress sudo -u "$SERVICE_USER" \
                        "$INSTALL_DIR/.venv/bin/pip-sync" combined-requirements.lock
                else
                    run_with_progress sudo -u "$SERVICE_USER" \
                        "$INSTALL_DIR/.venv/bin/pip" install -r requirements.txt -r optional-requirements.txt
                fi
                rm -f combined-requirements.txt
            fi
        else
            if [ -f "requirements.lock" ]; then
                run_with_progress sudo -u "$SERVICE_USER" \
                    "$INSTALL_DIR/.venv/bin/pip-sync" requirements.lock
            else
                if sudo -u "$SERVICE_USER" \
                    "$INSTALL_DIR/.venv/bin/pip-compile" \
                    --strip-extras requirements.txt --output-file requirements.lock; then
                    run_with_progress sudo -u "$SERVICE_USER" \
                        "$INSTALL_DIR/.venv/bin/pip-sync" requirements.lock
                else
                    run_with_progress sudo -u "$SERVICE_USER" \
                        "$INSTALL_DIR/.venv/bin/pip" install -r requirements.txt
                fi
            fi
        fi
    fi

    print_status "Using Python environment: $INSTALL_DIR/.venv"

    # Fix permissions
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR/.venv"

    print_status "Autocaliweb installed successfully"
}

# Function to check python dependencies
check_python_dependencies() {
    print_status "Checking Python dependency health..."

    if [ ! -d "$INSTALL_DIR/.venv" ]; then
        print_warning "Python virtual environment not found at $INSTALL_DIR/.venv. Skipping dependency check."
        return 0
    fi

    # shellcheck disable=SC1091
    source "$INSTALL_DIR/.venv/bin/activate"

    # Check for conflicts and handle the result.
    if ! pip check >/dev/null 2>&1; then
        print_warning "Python dependency conflicts detected."

        if [ "$ACCEPT_ALL" = true ]; then
            print_status "Auto-accepting conflict resolution (--yes flag provided)."
            deactivate
            return 1 # Signal for the main script to attempt to fix
        fi

        # Show detailed error message for user
        pip check 2>&1 | head -n 10
        print_prompt "Attempt to fix conflicts? (y/N)" REPLY "true"
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            deactivate
            return 1 # Signal that fixes are needed
        else
            print_status "Python dependency fix skipped. Conflicts may cause issues."
            deactivate
            return 0
        fi
    else
        print_status "Python dependencies are healthy."
    fi

    # Show number of installed packages
    installed_count=$(sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" list --disable-pip-version-check --format=freeze 2>/dev/null | wc -l)
    print_status "Python packages installed in venv: $installed_count"

    # Verify critical optional modules
    if [ "$use_optional" = true ]; then
        #shellcheck disable=SC2043
        for mod in mutagen; do
            if ! sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/python" -c "import ${mod}" >/dev/null 2>&1; then
                print_warning "Optional module '${mod}' is not importable in venv. You may need to re-run installer or check logs."
            else
                print_status "Optional module '${mod}' available."
            fi
        done
    fi

    deactivate
    return 0
}

# Separate function for Calibre installation
install_calibre() {
    print_status "Installing Calibre..."
    mkdir -p /opt/calibre
    CALIBRE_RELEASE=$(curl -s https://api.github.com/repos/kovidgoyal/calibre/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    CALIBRE_VERSION=${CALIBRE_RELEASE#v}
    CALIBRE_ARCH=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/')

    download_with_retry "https://download.calibre-ebook.com/${CALIBRE_VERSION}/calibre-${CALIBRE_VERSION}-${CALIBRE_ARCH}.txz" "/tmp/calibre.txz"

    print_status "Extracting Calibre..."

    # --- For debug / prevent the freeze on Destrosea.com or low resource system
    # if ! command -v "cpulimit" >/dev/null 2>&1; then
    #     sudo apt-get install cpulimit
    # fi
    set +e # Let's allow that error
    # Run tar in the background and capture its PID
    #run_with_progress
    XZ_OPT="--memlimit=1024MiB" tar xvf /tmp/calibre.txz -C /opt/calibre # &
    #TAR_PID=$!
    #print_verbose "TAR_PID= $TAR_PID"
    # Wait for a second to ensure the process is fully started
    #sleep 1
    # Apply the CPU limit to the background process
    #cpulimit --limit=50 --pid $TAR_PID
    # Wait for the tar process to finish and capture its exit code
    #wait $TAR_PID
    EXIT_CODE=$?
    set -e #
    # Check the exit code for success or failure
    if [ $EXIT_CODE -ne 0 ]; then
        # ---------------------------------
        # if ! run_with_progress XZ_OPT="--memlimit=1024MiB" tar xf /tmp/calibre.txz -C /opt/calibre; then
        print_warning "Failed to extract Calibre. Autocaliweb will still be installed, but you need to install Calibre manually."
        CALIBRE_INSTALL_FAILED=1
    else
        print_status "Running Calibre postinstall..."
        if ! run_with_progress /opt/calibre/calibre_postinstall; then
            print_warning "Calibre postinstall failed. You may need to complete setup manually."
            CALIBRE_INSTALL_FAILED=1
        else
            rm -f /tmp/calibre.txz
            chown -R "$SERVICE_USER:$SERVICE_GROUP" /opt/calibre
            echo "$CALIBRE_RELEASE" >"$INSTALL_DIR"/CALIBRE_RELEASE
            CALIBRE_INSTALL_FAILED=0
        fi
    fi
    if [[ "${CALIBRE_INSTALL_FAILED:-0}" -eq 1 ]]; then
        print_warning "Calibre installation did not complete successfully."
        print_warning "Please install Calibre manually from https://calibre-ebook.com/download and re-run Autocaliweb if needed."
    fi
}

# Separate function for Kepubify installation
install_kepubify() {
    print_status "Installing Kepubify..."
    KEPUBIFY_RELEASE=$(curl -s https://api.github.com/repos/pgaskin/kepubify/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    ARCH=$(uname -m | sed 's/x86_64/64bit/;s/aarch64/arm64/')

    download_with_retry "https://github.com/pgaskin/kepubify/releases/download/${KEPUBIFY_RELEASE}/kepubify-linux-${ARCH}" "/usr/bin/kepubify"
    chmod +x /usr/bin/kepubify
    echo "$KEPUBIFY_RELEASE" >"$INSTALL_DIR"/KEPUBIFY_RELEASE
}

make_koreader_plugin() {
    print_status "Creating ACWSync plugin for KOReader..."
    if [ -d "$INSTALL_DIR"/koreader/plugins/acwsync.koplugin ]; then
        # Delete the digest and plugin zip files if exists
        rm "$INSTALL_DIR/koreader/plugins/acwsync.koplugin/"*.digest 2>/dev/null || true
        rm "$INSTALL_DIR/koreader/plugins/koplugin.zip" 2>/dev/null || true
        cd "$INSTALL_DIR/koreader/plugins"

        print_status "Calculating digest of plugin files..."
        PLUGIN_DIGEST=$(find acwsync.koplugin -type f -name "*.lua" -o -name "*.json" | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
        print_status "Plugin digest: $PLUGIN_DIGEST"

        echo "Plugin files digest: $PLUGIN_DIGEST" >acwsync.koplugin/"${PLUGIN_DIGEST}".digest
        {
            echo "Build date: $(date)"
            echo "Files included:"
            find acwsync.koplugin -type f -name "*.lua" -o -name "*.json" | sort
        } >>acwsync.koplugin/"${PLUGIN_DIGEST}".digest
        zip -r koplugin.zip acwsync.koplugin/
        cp -r "$INSTALL_DIR/koreader/plugins/koplugin.zip" "$INSTALL_DIR/cps/static"

        print_status "Created koplugin.zip from acwsync.koplugin folder with digest file: ${PLUGIN_DIGEST}.digest"
    else
        print_warning "acwsync.koplugin directory not found, skipping plugin creation"
    fi
}

# Install external tools (with detection)
install_external_tools() {
    print_status "Checking for external tools..."

    # Check for existing Calibre installation
    if command -v calibre >/dev/null 2>&1 || command -v ebook-convert >/dev/null 2>&1; then
        print_status "Calibre already installed, skipping installation"
        # To be tested: Is ownership of calibre needed? If so we can do that
        print_warning "Make sure user: $SERVICE_USER has ownership of Calibre folder"
        CALIBRE_PATH=$(dirname "$(which ebook-convert 2>/dev/null || which calibre)")
        # Create Calibre version file
        if command -v calibre >/dev/null 2>&1; then
            if calibre --version | head -1 | cut -d' ' -f3 | sed 's/)//' >"$INSTALL_DIR"/CALIBRE_RELEASE 2>/dev/null; then
                print_status "Calibre version file created successfully"
            else
                print_warning "Could not determine Calibre version, using 'Unknown'"
                echo "Unknown" >"$INSTALL_DIR"/CALIBRE_RELEASE
            fi
        else
            echo "Unknown" >"$INSTALL_DIR"/CALIBRE_RELEASE
        fi
        print_status "Using existing Calibre at: $CALIBRE_PATH"
    else
        local install_ET_calibre=false
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-installing Calibre (--yes flag provided)"
            install_ET_calibre=true
        else
            print_prompt "Calibre not found. Install Calibre? (y/n)" REPLY "true"
            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                install_ET_calibre=true
            fi
        fi

        if [ "${install_ET_calibre}" = ture ]; then
            install_calibre
        else
            print_warning "Skipping Calibre installation. You'll need to install it manually."
            echo "Unknown" >"$INSTALL_DIR"/CALIBRE_RELEASE
        fi
    fi

    # Check for existing Kepubify installation
    if command -v kepubify >/dev/null 2>&1; then
        print_status "Kepubify already installed, skipping installation"
        KEPUBIFY_PATH=$(which kepubify)
        kepubify --version | head -1 | cut -d' ' -f2 >"$INSTALL_DIR"/KEPUBIFY_RELEASE
        print_status "Using existing Kepubify at: $KEPUBIFY_PATH"
    else
        local install_ET_kepubify=false
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-installing Kepubify (--yes flag provided)"
            install_ET_kepubify=true
        else
            print_prompt "Kepubify not found. Install Kepubify? (y/n)" REPLY "true"
            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                install_ET_kepubify=true
            fi
        fi

        if [ "${install_ET_kepubify}" = true ]; then
            install_kepubify
        else
            print_warning "Skipping Kepubify installation. You'll need to install it manually."
            echo "Unknown" >"$INSTALL_DIR"/KEPUBIFY_RELEASE
        fi
    fi

    # Check for existing unrar installation
    if command -v unrar >/dev/null 2>&1; then
        UNRAR_CMD="unrar"
    elif command -v unrar-free >/dev/null 2>&1; then
        UNRAR_CMD="unrar-free"
    else
        UNRAR_CMD=""
        print_warning "Neither 'unrar-free' nor 'unrar' was found. RAR support is unavailable."
        print_status "To enable processing and extraction of RAR archives,
        you must manually install your preferred 'unrar' utility (e.g., 'unrar' or 'unrar-free').
        After install add it from Admin → Edit Basic Configuration → External binaries → Location of Unrar binary"
    fi
    # If we found unrar, add UNRAR_PATH to app.db
    # Based on scenario, app.db might not exists yet.
    if [[ ! "$UNRAR_CMD" = "" ]]; then
        UNRAR_PATH=$(which "$UNRAR_CMD")
        unrar_version=$("$UNRAR_CMD" -V | grep -v '^\s*$' | head -1 | cut -d' ' -f2)
        print_status "Using existing RAR utility: $UNRAR_CMD version: ${unrar_version} at: $UNRAR_PATH."
    fi
}

create_app_db_programmatically() {
    local tmp_script
    tmp_script="/tmp/init_app_db.py"
    trap 'rm -f "$tmp_script" >/dev/null 2>&1 || true' EXIT
    print_status "Creating app.db programmatically with all required tables..."

    # Create a comprehensive Python script to initialize both databases
    cat >/tmp/init_app_db.py <<EOF
#!/usr/bin/env python3
import sys
import os
sys.path.insert(0, '$INSTALL_DIR')

# Import required modules
from cps import ub
from cps.config_sql import _migrate_table, _Settings, _Flask_Settings
from sqlalchemy import create_engine
from sqlalchemy.orm import scoped_session, sessionmaker

# Initialize the user database (creates user, shelf, etc. tables)
print("Initializing user database...")
ub.init_db('$CONFIG_DIR/app.db')

# Initialize the settings database (creates settings table)
print("Initializing settings database...")
engine = create_engine('sqlite:///$CONFIG_DIR/app.db', echo=False)
Session = scoped_session(sessionmaker())
Session.configure(bind=engine)
session = Session()

# Create settings tables
_Settings.__table__.create(bind=engine, checkfirst=True)
_Flask_Settings.__table__.create(bind=engine, checkfirst=True)

# Migrate any missing columns
_migrate_table(session, _Settings)

# Create default settings entry
try:
    existing_settings = session.query(_Settings).first()
    if not existing_settings:
        print("Creating default settings entry...")
        default_settings = _Settings()
        session.add(default_settings)
        session.commit()
        print("Default settings created successfully")
    else:
        print("Settings entry already exists")
except Exception as e:
    print(f"Error creating settings: {e}")
    session.rollback()

session.close()
print("Database initialization completed successfully")
EOF

    # Run the initialization script as the service user
    if ! sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/python" /tmp/init_app_db.py; then
        print_error "Database initialization failed. Check Python environment and permissions."
        print_error "Try running: sudo -u $SERVICE_USER $INSTALL_DIR/.venv/bin/python -c 'import sys; print(sys.path)'"
        exit 1
    fi

    # If we got here, initialization succeeded no need for another if
    print_status "app.db created successfully with all tables at $CONFIG_DIR/app.db"

    # Set proper ownership and permissions for the database file
    chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/app.db"
    chmod 664 "$CONFIG_DIR/app.db" # Read/write for owner and group

    # Also ensure the directory has proper permissions
    chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR"
    chmod 2775 "$CONFIG_DIR" # Directory needs execute permission

    print_status "Database permissions set correctly"

    # Verify the settings table exists
    if sudo -u "$SERVICE_USER" sqlite3 "$CONFIG_DIR/app.db" "SELECT name FROM sqlite_master WHERE type='table' AND name='settings';" | grep -q settings; then
        print_status "Settings table verified successfully"
    else
        print_error "Settings table was not created properly"
        exit 1
    fi
    rm -f "$tmp_script" >/dev/null 2>&1 || true
}

initialize_databases() {
    local current_scenario="$1"
    print_status "Initializing databases..."

    # Binary paths detection (KEPUBIFY_PATH, etc.) should now be done INSIDE update_app_db_settings
    # OR ensured globally, but we moved it into the updater for simplicity/reusability.

    # First check if app.db already exists
    if [ -f "$CONFIG_DIR/app.db" ]; then
        print_status "Existing app.db found, preserving user data"
    else
        # No existing app.db, check if we have a template to copy from
        if [[ "$current_scenario" =~ "with_template" ]]; then
            print_status "Template app.db found, copying to $CONFIG_DIR"
            cp "$INSTALL_DIR/library/app.db" "$CONFIG_DIR/app.db"
            chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/app.db"
            chmod 664 "$CONFIG_DIR/app.db"
        else
            print_warning "No template app.db found, creating database programmatically..."
            create_app_db_programmatically
        fi
    fi

    # Ensure log file exists
    if [ ! -f "$CONFIG_DIR/autocaliweb.log" ]; then
        touch "$CONFIG_DIR/autocaliweb.log"
        chmod 664 "$CONFIG_DIR/autocaliweb.log"
    fi

    # Call the new reusable update function to set paths and binaries
    update_app_db_settings
}

# Create systemd service
create_systemd_service() {
    print_status "Creating systemd service..."

    tee /etc/systemd/system/autocaliweb.service >/dev/null <<EOF
[Unit]
Description=Autocaliweb
After=network.target
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=/etc/autocaliweb/environment
Environment=PATH=$INSTALL_DIR/.venv/bin:/usr/bin:/bin
Environment=PYTHONPATH=$INSTALL_DIR
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
Environment=CALIBRE_DBPATH=$CONFIG_DIR
ExecStart=$INSTALL_DIR/.venv/bin/python $INSTALL_DIR/cps.py -p $CONFIG_DIR/app.db

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable autocaliweb
    print_status "Systemd service created and enabled"
}

# Set up configuration files
setup_configuration() {
    print_status "Setting up configuration files..."

    # Update dirs.json with correct paths
    cat >"$INSTALL_DIR/dirs.json" <<EOF
{
  "ingest_folder": "$INGEST_DIR",
  "calibre_library_dir": "$CALIBRE_LIB_DIR",
  "tmp_conversion_dir": "$CONFIG_DIR/.acw_conversion_tmp"
}
EOF

    if [ "$VERBOSE" = "1" ]; then
        VERSION=$("$INSTALL_DIR"/.venv/bin/python -c "import sys; sys.path.insert(0, '${INSTALL_DIR}'); from cps.constants import STABLE_VERSION; print(STABLE_VERSION)")
    else
        VERSION=$("$INSTALL_DIR"/.venv/bin/python -c "import sys; sys.path.insert(0, '${INSTALL_DIR}'); from cps.constants import STABLE_VERSION; print(STABLE_VERSION)" 2>/dev/null)
    fi
    echo "$VERSION" >"$INSTALL_DIR/ACW_RELEASE"
    print_status "Configuration files updated"
}

# V 3.7.4: metadata.db creation updated using original calibre schema
# complex SQL views (like meta, tag_browser_tags, etc.) and triggers
# (like books_insert_trg, fkc_*) that rely on custom SQLite functions
# like title_sort(), uuid4(), or books_list_filter() ignored.
# calibredb or Calibre application itself will take care of that.
ensure_calibre_library() {

    # Check if the metadata.db file exists.
    if [ ! -f "$CALIBRE_LIB_DIR/metadata.db" ]; then
        print_status "Creating robust Calibre library structure..."

        mkdir -p "$CALIBRE_LIB_DIR"

        # Use calibredb if available to create the full structure automatically
        if command -v calibredb >/dev/null 2>&1; then
            # list command forces creation of the full library structure
            calibredb --library-path="$CALIBRE_LIB_DIR" list >/dev/null 2>&1 || true
        else
            # Create the essential, non-custom-function-dependent tables and indices
            # This ensures the database is structurally sound for Calibre's first run.
            sqlite3 "$CALIBRE_LIB_DIR/metadata.db" <<EOF
-- CORE METADATA TABLES
CREATE TABLE IF NOT EXISTS "authors" (
	"id"	INTEGER,
	"name"	TEXT NOT NULL COLLATE NOCASE,
	"sort"	TEXT COLLATE NOCASE,
	"link"	TEXT NOT NULL DEFAULT '',
	PRIMARY KEY("id"),
	UNIQUE("name")
);
CREATE TABLE IF NOT EXISTS "books" (
	"id"	INTEGER,
	"title"	TEXT NOT NULL DEFAULT 'Unknown' COLLATE NOCASE,
	"sort"	TEXT COLLATE NOCASE,
	"timestamp"	TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
	"pubdate"	TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
	"series_index"	REAL NOT NULL DEFAULT 1.0,
	"author_sort"	TEXT COLLATE NOCASE,
	"isbn"	TEXT DEFAULT '' COLLATE NOCASE,
	"lccn"	TEXT DEFAULT '' COLLATE NOCASE,
	"path"	TEXT NOT NULL DEFAULT '',
	"flags"	INTEGER NOT NULL DEFAULT 1,
	"uuid"	TEXT,
	"has_cover"	BOOL DEFAULT 0,
	"last_modified"	TIMESTAMP NOT NULL DEFAULT '2000-01-01 00:00:00+00:00',
	PRIMARY KEY("id" AUTOINCREMENT)
);
CREATE TABLE IF NOT EXISTS "tags" (
	"id"	INTEGER,
	"name"	TEXT NOT NULL COLLATE NOCASE,
	"link"	TEXT NOT NULL DEFAULT '',
	PRIMARY KEY("id"),
	UNIQUE("name")
);
CREATE TABLE IF NOT EXISTS "languages" (
	"id"	INTEGER,
	"lang_code"	TEXT NOT NULL COLLATE NOCASE,
	"link"	TEXT NOT NULL DEFAULT '',
	PRIMARY KEY("id"),
	UNIQUE("lang_code")
);
CREATE TABLE IF NOT EXISTS "publishers" (
	"id"	INTEGER,
	"name"	TEXT NOT NULL COLLATE NOCASE,
	"sort"	TEXT COLLATE NOCASE,
	"link"	TEXT NOT NULL DEFAULT '',
	PRIMARY KEY("id"),
	UNIQUE("name")
);
CREATE TABLE IF NOT EXISTS "ratings" (
	"id"	INTEGER,
	"rating"	INTEGER CHECK("rating" > -1 AND "rating" < 11),
	"link"	TEXT NOT NULL DEFAULT '',
	PRIMARY KEY("id"),
	UNIQUE("rating")
);
CREATE TABLE IF NOT EXISTS "series" (
	"id"	INTEGER,
	"name"	TEXT NOT NULL COLLATE NOCASE,
	"sort"	TEXT COLLATE NOCASE,
	"link"	TEXT NOT NULL DEFAULT '',
	PRIMARY KEY("id"),
	UNIQUE("name")
);

-- LINK TABLES (M-to-N or 1-to-N relationships)
CREATE TABLE IF NOT EXISTS "books_authors_link" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"author"	INTEGER NOT NULL,
	UNIQUE("book","author"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "books_languages_link" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"lang_code"	INTEGER NOT NULL,
	"item_order"	INTEGER NOT NULL DEFAULT 0,
	UNIQUE("book","lang_code"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "books_publishers_link" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"publisher"	INTEGER NOT NULL,
	UNIQUE("book"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "books_ratings_link" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"rating"	INTEGER NOT NULL,
	UNIQUE("book","rating"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "books_series_link" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"series"	INTEGER NOT NULL,
	UNIQUE("book"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "books_tags_link" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"tag"	INTEGER NOT NULL,
	UNIQUE("book","tag"),
	PRIMARY KEY("id")
);

-- OTHER ESSENTIAL TABLES
CREATE TABLE IF NOT EXISTS "data" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"format"	TEXT NOT NULL COLLATE NOCASE,
	"uncompressed_size"	INTEGER NOT NULL,
	"name"	TEXT NOT NULL,
	UNIQUE("book","format"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "comments" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"text"	TEXT NOT NULL COLLATE NOCASE,
	UNIQUE("book"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "identifiers" (
	"id"	INTEGER,
	"book"	INTEGER NOT NULL,
	"type"	TEXT NOT NULL DEFAULT 'isbn' COLLATE NOCASE,
	"val"	TEXT NOT NULL COLLATE NOCASE,
	UNIQUE("book","type"),
	PRIMARY KEY("id")
);
CREATE TABLE IF NOT EXISTS "library_id" (
	"id"	INTEGER,
	"uuid"	TEXT NOT NULL,
	PRIMARY KEY("id"),
	UNIQUE("uuid")
);
CREATE TABLE IF NOT EXISTS "preferences" (
	"id"	INTEGER,
	"key"	TEXT NOT NULL,
	"val"	TEXT NOT NULL,
	PRIMARY KEY("id"),
	UNIQUE("key")
);

-- ESSENTIAL INDICES FOR PERFORMANCE
CREATE INDEX IF NOT EXISTS "authors_idx" ON "books" ("author_sort" COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS "books_authors_link_aidx" ON "books_authors_link" ("author");
CREATE INDEX IF NOT EXISTS "books_authors_link_bidx" ON "books_authors_link" ("book");
CREATE INDEX IF NOT EXISTS "books_idx" ON "books" ("sort" COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS "books_tags_link_aidx" ON "books_tags_link" ("tag");
CREATE INDEX IF NOT EXISTS "books_tags_link_bidx" ON "books_tags_link" ("book");
CREATE INDEX IF NOT EXISTS "data_idx" ON "data" ("book");
CREATE INDEX IF NOT EXISTS "formats_idx" ON "data" ("format");
EOF
        fi

        # Ensure correct ownership and permissions
        chown -R "$SERVICE_USER:$SERVICE_GROUP" "$CALIBRE_LIB_DIR"
        print_status "Calibre library initialized with structural tables."
    fi
}

# Set permissions. Redundant but useful if the installation directory pre-exists or after failed install.
set_permissions() {
    print_status "Setting permissions..."

    # Set ownership for all directories
    chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$INSTALL_DIR" "$CONFIG_DIR" "$CALIBRE_LIB_DIR" "$INGEST_DIR"

    # Set executable permissions for scripts
    find "$INSTALL_DIR/scripts" -name "*.py" -exec chmod +x {} \;
    chmod +x "$INSTALL_DIR/cps.py"

    print_status "Permissions set successfully"
}

# Create startup script
create_startup_script() {
    print_status "Creating startup script..."

    cat >"$INSTALL_DIR/start_autocaliweb.sh" <<EOF
#!/bin/bash
# Copyright (C) 2025 Autocaliweb
cd "$INSTALL_DIR"
export PYTHONPATH="$INSTALL_DIR/scripts:$INSTALL_DIR"
export CALIBRE_DBPATH="$CONFIG_DIR"
source .venv/bin/activate
python cps.py
EOF

    chmod +x "$INSTALL_DIR/start_autocaliweb.sh"
    chown "${SERVICE_USER}":"${SERVICE_GROUP}" "$INSTALL_DIR/start_autocaliweb.sh"
    print_status "Startup script created at $INSTALL_DIR/start_autocaliweb.sh"
}

# Create Ingest Service
create_acw_ingest_service() {
    print_status "Creating systemd service wrapper for acw-ingest-service..."

    # Create wrapper script
    tee "${INSTALL_DIR}"/scripts/ingest_watcher.sh >/dev/null <<EOF
#!/bin/bash

# Source the environment file to ensure all variables are loaded,
# even if called manually outside of systemd.
if [ -f "/etc/autocaliweb/environment" ]; then
    source "/etc/autocaliweb/environment"
fi

INSTALL_PATH="${INSTALL_DIR}"
PYTHONPATH=${INSTALL_DIR}
CALIBRE_DBPATH=${CONFIG_DIR}
WATCH_FOLDER=\$(grep -o '"ingest_folder": "[^"]*' \${INSTALL_PATH}/dirs.json | grep -o '[^"]*\$')
echo "[acw-ingest-service] Watching folder: \$WATCH_FOLDER"

# Monitor the folder for new files
/usr/bin/inotifywait -m -r --format="%e %w%f" -e close_write -e moved_to "\$WATCH_FOLDER" |
while read -r events filepath ; do
    echo "[acw-ingest-service] New files detected - \$filepath - Starting Ingest Processor..."
    # Use the Python interpreter from the virtual environment
    \${INSTALL_PATH}/.venv/bin/python \${INSTALL_PATH}/scripts/ingest_processor.py "\$filepath"
done
EOF
    chmod +x "${INSTALL_DIR}"/scripts/ingest_watcher.sh

    # --- acw-ingest-service ---
    print_status "Creating systemd service for acw-ingest-service..."
    cat <<EOF | tee /etc/systemd/system/acw-ingest-service.service
[Unit]
Description=Autocaliweb Ingest Processor Service
After=autocaliweb.service
Requires=autocaliweb.service

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=/etc/autocaliweb/environment
Environment=HOME=${CONFIG_DIR}
ExecStart=/bin/bash ${INSTALL_DIR}/scripts/ingest_watcher.sh
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable acw-ingest-service
    print_status "Autocaliweb ingest service created and enabled"
}

create_auto_zipper_service() {
    print_status "Creating systemd service for acw-auto-zipper..."

    # Create wrapper script
    tee "${INSTALL_DIR}"/scripts/auto_zipper_wrapper.sh >/dev/null <<EOF
#!/bin/bash

# Source virtual environment
source ${INSTALL_DIR}/.venv/bin/activate

WAKEUP="23:59"

while true; do
    # Replace expr with modern Bash arithmetic (safer and less prone to parsing issues)
    # fix: expr: non-integer argument and sleep: missing operand
    SECS=\$(( \$(date -d "\$WAKEUP" +%s) - \$(date -d "now" +%s) ))
    if [[ \$SECS -lt 0 ]]; then
        SECS=\$(( \$(date -d "tomorrow \$WAKEUP" +%s) - \$(date -d "now" +%s) ))
    fi
    echo "[acw-auto-zipper] Next run in \$SECS seconds."
    sleep \$SECS &
    wait \$!

    # Use virtual environment python
    python ${INSTALL_DIR}/scripts/auto_zip.py

    if [[ \$? == 1 ]]; then
    echo "[acw-auto-zipper] Error occurred during script initialisation."
    elif [[ \$? == 2 ]]; then
    echo "[acw-auto-zipper] Error occurred while zipping today's files."
    elif [[ \$? == 3 ]]; then
    echo "[acw-auto-zipper] Error occurred while trying to remove zipped files."
    fi

    sleep 60
done
EOF

    chmod +x "${INSTALL_DIR}"/scripts/auto_zipper_wrapper.sh
    chown "${SERVICE_USER}":"${SERVICE_GROUP}" "${INSTALL_DIR}"/scripts/auto_zipper_wrapper.sh

    # Create systemd service
    cat <<EOF | tee /etc/systemd/system/acw-auto-zipper.service
[Unit]
Description=Autocaliweb Auto Zipper Service
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=/etc/autocaliweb/environment
Environment=CALIBRE_DBPATH=${CONFIG_DIR}
ExecStart=${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable acw-auto-zipper
    print_status "Auto-zipper service created and enabled"
}

# --- metadata-change-detector service
# This would require cover_enforcer.py to have a continuous watch mode
create_metadata_change_detector() {
    print_status "Creating systemd service for metadata-change-detector..."
    # Create wrapper script
    tee "${INSTALL_DIR}"/scripts/metadata_change_detector_wrapper.sh >/dev/null <<EOF
#!/bin/bash
# metadata_change_detector_wrapper.sh - Wrapper for periodic metadata enforcement

# Source virtual environment
source ${INSTALL_DIR}/.venv/bin/activate

# Configuration
CHECK_INTERVAL=300  # Check every 5 minutes (300 seconds)
METADATA_LOGS_DIR="${INSTALL_DIR}/metadata_change_logs"

echo "[metadata-change-detector] Starting metadata change detector service..."
echo "[metadata-change-detector] Checking for changes every \$CHECK_INTERVAL seconds"

while true; do
    # Check if there are any log files to process
    if [ -d "\$METADATA_LOGS_DIR" ] && [ "\$(ls -A \$METADATA_LOGS_DIR 2>/dev/null)" ]; then
        echo "[metadata-change-detector] Found metadata change logs, processing..."

        # Process each log file
        for log_file in "\$METADATA_LOGS_DIR"/*.json; do
            if [ -f "\$log_file" ]; then
                log_name=\$(basename "\$log_file")
                echo "[metadata-change-detector] Processing log: \$log_name"

                # Call cover_enforcer.py with the log file
                 ${INSTALL_DIR}/.venv/bin/python  ${INSTALL_DIR}/scripts/cover_enforcer.py --log "\$log_name"

                if [ \$? -eq 0 ]; then
                    echo "[metadata-change-detector] Successfully processed \$log_name"
                else
                    echo "[metadata-change-detector] Error processing \$log_name"
                fi
            fi
        done
    else
        echo "[metadata-change-detector] No metadata changes detected"
    fi

    echo "[metadata-change-detector] Sleeping for \$CHECK_INTERVAL seconds..."
    sleep \$CHECK_INTERVAL
done
EOF

    cat <<EOF | tee /etc/systemd/system/metadata-change-detector.service
[Unit]
Description=Autocaliweb Metadata Change Detector
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=/etc/autocaliweb/environment
Environment=CALIBRE_DBPATH=$CONFIG_DIR
Environment=HOME=$
ExecStart=/bin/bash ${INSTALL_DIR}/scripts/metadata_change_detector_wrapper.sh
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable metadata-change-detector
    print_status "Autocaliweb Metadata Change Detector service created and enabled"
}

run_auto_library() {
    print_status "Running auto library setup..."

    "${INSTALL_DIR}"/.venv/bin/python "${INSTALL_DIR}"/scripts/auto_library.py || true
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        print_status "Auto library setup completed successfully"
        return 0
    else
        print_error "Auto library setup failed with exit code: $exit_code"
        return $exit_code
    fi
}

# It is over-kill but let's make sure the permissions are set
set_acw_permissions() {
    declare -a requiredDirs=("$INSTALL_DIR" "$CALIBRE_LIB_DIR" "$CONFIG_DIR")

    print_status "Setting ownership of directories to $SERVICE_USER:$SERVICE_GROUP..."

    for d in "${requiredDirs[@]}"; do
        if [ -d "$d" ]; then
            chown -R "$SERVICE_USER:$SERVICE_GROUP" "$d"
            chmod -R 2775 "$d"
            print_status "Set permissions for '$d'"
        fi
    done
}

verify_installation() {
    print_status "Verifying installation..."
    local max_attempts=30
    local attempt=1
    local http_code

    while [ "$attempt" -le "$max_attempts" ]; do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8083 || echo "000")

        if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
            print_status "✅ Web interface is responding"
            return 0
        fi

        print_status "Attempt $attempt/$max_attempts: HTTP $http_code, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done

    print_warning "⚠️  Web interface may not be ready yet. Check 'sudo journalctl -u autocaliweb -f'"
    return 0
    # attempt=1
    # while [ "$attempt" -le "$max_attempts" ]; do
    # # Use a more specific healthcheck like the Dockerfile
    # # --fail: Fail silently on HTTP errors (e.g., 404, 500)
    # # -sS: Silent mode, but show errors
    # # -m 5: Set a 5-second timeout for the transfer
    # # grep -q: search for the status with a quiet output
    # if curl --fail -sS -m 5 http://localhost:8083/health | grep -q '"status":"ok"'; then
    # print_status "✅ Web service is healthy and responding!"
    # return 0
    # fi

    # print_status "Attempt $attempt/$max_attempts: Web service is not ready yet. Waiting..."
    # sleep 2
    # attempt=$((attempt + 1))
    # done

}

verify_services() {
    local failed_services=()

    for service in autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector; do
        if ! systemctl is-active --quiet "$service"; then
            failed_services+=("$service")
        fi
    done

    if [ ${#failed_services[@]} -gt 0 ]; then
        print_warning "Some services failed to start: ${failed_services[*]}"
        print_warning "Check logs with: sudo journalctl -u <service-name> -f"
    fi
}

cleanup_on_failure() {
    echo ERR
    print_error "Installation failed, cleaning up..."

    # Stop and disable services
    systemctl stop autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector 2>/dev/null || true
    systemctl disable autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector 2>/dev/null || true

    # Remove service files
    rm -f /etc/systemd/system/autocaliweb.service
    rm -f /etc/systemd/system/acw-ingest-service.service
    rm -f /etc/systemd/system/acw-auto-zipper.service
    rm -f /etc/systemd/system/metadata-change-detector.service
    rm -f /tmp/uv-*.lock

    systemctl daemon-reload
}

# setup_permanent_environment_variables - Sets up environment variables for Autocaliweb.
# This function creates a dedicated file for systemd services and also adds
# the variables to the system-wide environment for other applications.
setup_permanent_environment_variables() {
    print_status "Setting up permanent environment variables for Autocaliweb..."

    # Ensure all required directories are in place
    mkdir -p /etc/autocaliweb

    # Create the environment file for systemd services.
    # This file is used by the 'EnvironmentFile=' directive in the service units.
    cat >/etc/autocaliweb/environment <<EOF
ACW_INSTALL_DIR=${INSTALL_DIR}
ACW_CONFIG_DIR=${CONFIG_DIR}
ACW_USER=${SERVICE_USER}
ACW_GROUP=${SERVICE_GROUP}
LIBRARY_DIR=${CALIBRE_LIB_DIR}
INGEST_DIR=${INGEST_DIR}
PYTHONPATH=${INSTALL_DIR}/.venv/bin
CALIBRE_DBPATH=${CONFIG_DIR}
EOF

    # Define the environment variables to be added to /etc/environment.
    local env_vars=(
        "ACW_INSTALL_DIR=${INSTALL_DIR}"
        "ACW_CONFIG_DIR=${CONFIG_DIR}"
        "ACW_USER=${SERVICE_USER}"
        "ACW_GROUP=${SERVICE_GROUP}"
        "LIBRARY_DIR=${CALIBRE_LIB_DIR}"
        "INGEST_DIR=${INGEST_DIR}"
    )

    # Loop through the variables and add or update them in /etc/environment.
    for var in "${env_vars[@]}"; do
        local key="${var%%=*}"
        if grep -q "^${key}=" /etc/environment 2>/dev/null; then
            # If the variable already exists, update its value.
            sed -i "/^${key}=/c\\${var}" /etc/environment
            print_status "Updated ${BOLD}${key}${RESET} in /etc/environment"
        else
            # If the variable doesn't exist, add it.
            echo "$var" >>/etc/environment
            print_status "Added ${BOLD}${key}${RESET} to /etc/environment"
        fi
    done

    # Export the variables for the current shell session.
    # only affects the current script's shell environment (which is about to exit).
    export ACW_INSTALL_DIR="${INSTALL_DIR}"
    export ACW_CONFIG_DIR="${CONFIG_DIR}"
    export ACW_USER="${SERVICE_USER}"
    export ACW_GROUP="${SERVICE_GROUP}"
    export LIBRARY_DIR="${CALIBRE_LIB_DIR}"
    export INGEST_DIR="${INGEST_DIR}"

    print_status "All environment variables configured successfully."
    print_warning "NOTE: For changes to take effect in your current terminal session,"
    print_warning "      you must run the following command manually:"
    print_warning "      ${BOLD}source /etc/environment${RESET} or ${BOLD}. /etc/environment${RESET}"
}

# Temporary function used by install_flask_limiter() to display recommended package names.
# TODO: make pkg_bin_map array more distro aware and combine this function with it.
get_package_name() {
    local package_id="$1"

    case "$package_id" in
        "redis")
            case "$DISTRO_FAMILY" in
                ubuntu | debian)
                    echo "redis-server"
                    ;;
                fedora)
                    echo "valkey"
                    ;;
                *)
                    # Includes fedora, centos, arch, opensuse, sles, etc.
                    echo "redis"
                    ;;
            esac
            ;;
        "memcached")
            # Memcached package name is consistent across major distros
            echo "memcached"
            ;;
        *)
            print_error "Unknown package ID requested: $package_id"
            return 1
            ;;
    esac
}

# Helper function to check if a systemd service is currently running (active)
# Returns 0 if active, anything else otherwise. ( 1 not exist, 3 inactive, 4 failed)
is_service_active() {
    local service_name=$1
    # Check if systemctl exists and the service is active.
    # We suppress output to keep the check clean.
    systemctl is-active --quiet "$service_name" 2>/dev/null
    return $?
}

# TODO: for V 4.xx consider installing the package, currenty just give recommendation.
install_flask_limiter() {
    local REDIS_PKG_NAME
    local MEMCACHED_PKG_NAME
    REDIS_PKG_NAME=$(get_package_name "redis")
    MEMCACHED_PKG_NAME=$(get_package_name "memcached")

    local services_to_check=("valkey.service" "redis.service" "memcached.service")
    local found_active_caching_service=false

    print_verbose "Caching Service Check..."

    # Iterate through known services and check for active status
    for service in "${services_to_check[@]}"; do
        if is_service_active "$service"; then
            print_status "Found active caching service: ${service}."
            found_active_caching_service=true
            break # Exit loop immediately if a running service is found
        else
            print_debug "Service check failed for: ${service}"
        fi
    done

    # Display the recommendation message based one active service was found or not
    if ! $found_active_caching_service; then
        print_warning "No active caching service (Redis/Valkey/Memcached) detected."
        echo ""
        echo "--------------------------------------------------------"
        echo " ${YELLOW}PRODUCTION SETUP NOTE: FLASK-LIMITER & CACHING REQUIRED${RESET}"
        echo "--------------------------------------------------------"

        echo "For production deployments, high traffic, or public access, we strongly recommend installing a caching server and configuring Flask-Limiter for Performance & Stability and Denial-of-Service (DoS) protection."
        echo ""
        echo "This installer did NOT automatically install these components due to varying system configurations."

        echo "To ensure application stability and security, please perform the following ${BOLD}manual steps${RESET}:"
        echo "1. Install a caching backend: ${BOLD}Redis/Valkey${RESET} (package: ${REDIS_PKG_NAME}) or ${BOLD}Memcached${RESET} (package: ${MEMCACHED_PKG_NAME})."
        echo "2. Open the firewall port (e.g., 6379 for Redis/Valkey or 11211 for Memcached)."
        echo "3. Configure your application's settings from Admin → Edit Basic Configuration → Security Settings:"
        echo "   • Configure Backend for Limiter"
        echo "   • Options for Limiter Backend"
    else
        echo "Configure your application's settings from Admin → Edit Basic Configuration → Security Settings:"
        echo "   • Configure Backend for Limiter"
        echo "   • Options for Limiter Backend"

    fi
}

# Define a helper function to run package cleanup, logging all output
# Intruduced in V.3.2, Disabled with V.3.7.2
_run_package_cleanup() {
    local cmd_array=("$@")
    local final_cmd_string

    ################################################################################
    # CRITICAL NOTE: PACKAGE REMOVAL STRATEGY
    #
    # We do not track pre-installed vs. script-installed packages (too slow).
    # We rely on the package manager, but this alters flags (manual/auto).
    #
    # RISK: System cleanup tools may wipe essential software due to flag changes.
    #       (A previous test removed 500+ packages and broke the system!)
    #
    # ACTION: Auto-removal is DISABLED. We only report installations.
    ################################################################################

    # Log the calculated command for debugging
    print_status "Calculated cleanup command: ${cmd_array[*]}"

    # Display the instructions to the user
    echo ""
    print_warning "AUTOMATIC REMOVAL DISABLED FOR SYSTEM SAFETY."
    print_status "To safely remove ${BOLD}${BLUE}Autocaliweb's direct dependencies${RESET}, please review the list below and run the following command manually.
          ${BOLD}NOTE:${RESET} If you need to keep any package from this list for another application, simply remove it from the command before execution."

    echo ""
    # Remove '-y' flag if present:
    cmd_array=("${cmd_array[@]/ -y/}")
    cmd_array=("${cmd_array[@]/-y/}") # Handle cases where -y is not prefixed with a space

    # Rebuild the final command string with 'sudo' prepended:
    final_cmd_string="sudo ${cmd_array[*]}"

    # Print the command in a clear, copy-pasteable color (Cyan)
    # We use printf to ensure special characters don't break the output
    printf "%s\n" "${BOLD}${CYAN}${final_cmd_string[*]}${RESET}"
    echo ""

    return 0
}

uninstall_packages_for_distro() {
    local packages_to_remove=()
    local PKG_COMMON=()
    local PKG_GRAPHICS_HEADLESS=()
    local PKG_GRAPHICS_DESKTOP=()
    local python_pkgs=()

    # --- 1. Determine package lists based on DISTRO_FAMILY (Mirroring Install Logic) ---
    case "$DISTRO_FAMILY" in
        ubuntu | debian)
            PKG_COMMON=("${PKG_COMMON_UBUNTU[@]}")
            PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_UBUNTU[@]}")
            PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_UBUNTU[@]}")
            ;;
        fedora)
            PKG_COMMON=("${PKG_COMMON_FEDORA[@]}")
            PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_FEDORA[@]}")
            PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_FEDORA[@]}")
            ;;
        centos | rhel)
            PKG_COMMON=("${PKG_COMMON_CENTOS[@]}")
            PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_CENTOS[@]}")
            PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_CENTOS[@]}")
            ;;
        arch)
            PKG_COMMON=("${PKG_COMMON_ARCH[@]}")
            PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_ARCH[@]}")
            PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_ARCH[@]}")
            ;;
        opensuse-leap)
            # For uninstall, we don't run 'install_opensuse_patterns',
            # but we DO need to calculate the versioned python packages to list them for removal.
            read -r -a python_pkgs <<<"$(get_opensuse_versioned_packages)"
            PKG_COMMON=("${python_pkgs[@]}")
            PKG_COMMON+=("${PKG_COMMON_OPENSUSE_LEAP[@]}")
            PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_OPENSUSE_LEAP[@]}")
            PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_OPENSUSE_LEAP[@]}")
            ;;
        opensuse-tumbleweed)
            read -r -a python_pkgs <<<"$(get_opensuse_versioned_packages)"
            PKG_COMMON=("${python_pkgs[@]}")
            PKG_COMMON+=("${PKG_COMMON_OPENSUSE_TW[@]}")
            PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_OPENSUSE_TW[@]}")
            PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_OPENSUSE_TW[@]}")
            ;;
        sles)
            read -r -a python_pkgs <<<"$(get_opensuse_versioned_packages)"
            PKG_COMMON=("${python_pkgs[@]}")
            PKG_COMMON+=("${PKG_COMMON_SLES[@]}")
            PKG_GRAPHICS_HEADLESS=("${PKG_GRAPHICS_HEADLESS_SLES[@]}")
            PKG_GRAPHICS_DESKTOP=("${PKG_GRAPHICS_DESKTOP_SLES[@]}")
            ;;
        *)
            print_warning "Unknown distribution family '$DISTRO_FAMILY'. Cannot determine dependency list for removal."
            ;;
    esac

    # --- 2. Combine lists based on Headless vs Desktop ---
    if [[ "$IS_HEADLESS" = "1" ]]; then
        packages_to_remove=("${PKG_COMMON[@]}" "${PKG_GRAPHICS_HEADLESS[@]}")
    else
        packages_to_remove=("${PKG_COMMON[@]}" "${PKG_GRAPHICS_DESKTOP[@]}")
    fi

    # --- 3. Report the result ---
    if [ ${#packages_to_remove[@]} -gt 0 ]; then
        print_status "Generating removal command for dependencies..."

        # Convert the base command string into an array (e.g., "dnf remove -y")
        # We still use PKG_MANAGER here to get the correct *command*,
        # even though we used DISTRO_FAMILY to get the *packages*.
        IFS=' ' read -r -a base_cmd <<<"${PKG_REMOVE_ARRAY[$PKG_MANAGER]}"

        # Final remove command combined
        local remove_cmd=("${base_cmd[@]}" "${packages_to_remove[@]}")

        # Pass to the safe reporter
        _run_package_cleanup "${remove_cmd[@]}"
    else
        print_status "No specific dependencies found to list."
    fi
}

uninstall_autocaliweb() {
    print_warning "This will permanently remove Autocaliweb and its data."
    print_prompt "Are you sure you want to continue? (y/n)" REPLY "true"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        print_status "Uninstall cancelled"
        exit 0
    fi

    # Variables to track cleanup steps for summary
    local data_deleted=false
    local kepubify_removed=false
    local calibre_uninstalled=false
    local packages_removed=false
    local packages_cleaned=false

    print_status "Stopping and disabling Autocaliweb services..."
    sudo systemctl stop autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector >/dev/null 2>&1 || true
    sudo systemctl disable autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector >/dev/null 2>&1 || true

    print_status "Removing systemd service files..."
    # Remove wrapper files too to prevent services from autorestart
    sudo rm -f /etc/systemd/system/autocaliweb.service \
        /etc/systemd/system/acw-ingest-service.service \
        /etc/systemd/system/acw-auto-zipper.service \
        /etc/systemd/system/metadata-change-detector.service \
        "${INSTALL_DIR}"/scripts/ingest_watcher.sh \
        "${INSTALL_DIR}"/scripts/auto_zipper_wrapper.sh \
        "${INSTALL_DIR}"/scripts/metadata_change_detector_wrapper.sh

    print_status "Reloading systemd daemon..."
    sudo systemctl daemon-reload

    print_status "Services stopped and removed successfully"

    # # --- NEW: Remove Autocaliweb-specific system dependencies ---
    # echo
    # print_status "Removing Autocaliweb core dependencies (Python, build tools, etc.)..."
    # if uninstall_packages_for_distro; then
    #     packages_removed=true
    # else
    #     print_warning "Some Autocaliweb dependencies may remain. Manual cleanup may be required."
    # fi

    # Backup
    print_prompt "Do you want to create backup for the databases? (y/N)" REPLY "true"
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        backup_existing_data
    fi

    # Ask about data deletion
    print_warning "The following will permanently delete ALL Autocaliweb data:"
    print_option "• Application files: $INSTALL_DIR"
    print_option "• Configuration data: $CONFIG_DIR"
    print_option "• Book ingest folder: $INGEST_DIR"
    print_option "• Autocaliweb Environment Variables"
    local data_reply=""
    print_prompt "Do you want to delete ALL data files? This cannot be undone! (y/N)" data_reply "false"
    if [[ "$data_reply" =~ ^[Yy]$ ]]; then
        # Ensure we are not inside a directory we are about to delete
        cd / || exit 1 # Change directory to root
        print_status "Removing all Autocaliweb data..."
        # Remove application and data directories
        print_status "Removing core application files from ${BOLD}${INSTALL_DIR}${RESET}..."
        sudo rm -rf "$INSTALL_DIR"
        print_status "Removing configuration files from ${BOLD}${CONFIG_DIR}${RESET}..."
        sudo rm -rf "$CONFIG_DIR"
        print_status "Removing ingest directory ${BOLD}${INGEST_DIR}${RESET}..."
        sudo rm -rf "$INGEST_DIR"
        local LINK_NAME
        LINK_NAME=$(basename "${INGEST_DIR}")
        if [ -L "${USER_HOME}/${LINK_NAME}" ]; then
            sudo rm "${USER_HOME}/${LINK_NAME}"
            print_verbose "${LINK_NAME} link removed."
        else
            print_verbose "${LINK_NAME} link does not exist, nothing to remove."
        fi
        print_status "Application data files removed"
        data_deleted=true
    else
        # IMPORTANT: After cleaning the environment variables all variables will be empty.
        # That could lead to the print to show "sudo rm -rf ." as a suggestion to the users.
        # Don't put dot as a punctuation at the end, and make sure those suggestion shows before we remove env.
        print_warning "Data files preserved. You can manually remove them later if needed:"
        print_status "  sudo rm -rf $CONFIG_DIR $INSTALL_DIR $INGEST_DIR"
    fi

    # Clean up any remaining lock files
    print_status "Cleaning up lock files..."
    sudo rm -f /tmp/ingest_processor.lock \
        /tmp/convert_library.lock \
        /tmp/cover_enforcer.lock \
        /tmp/kindle_epub_fixer.lock \
        /tmp/uv-*.lock

    # Remove external tools if they were installed by the installer
    echo
    if command -v kepubify >/dev/null 2>&1; then
        print_status "Kepubify executable was found and can be removed by this script."
        local confirm_kepubify_remove=""
        print_prompt "Do you want to remove Kepubify executable? (y/N)" confirm_kepubify_remove "true"
        if [[ "$confirm_kepubify_remove" =~ ^[Yy]$ ]]; then
            print_status "Removing Kepubify..."
            sudo rm -f "$(command -v kepubify)"
            kepubify_removed=true
        fi
    fi

    # --- NEW: Interactive Calibre Uninstall ---
    local calibre_uninstaller="/usr/bin/calibre-uninstall"
    if [ -x "$calibre_uninstaller" ]; then
        echo
        print_status "Calibre was likely installed via the official Calibre installer."
        print_warning "This script can run the official Calibre uninstaller for you."
        local confirm_calibre_uninstall=""
        print_prompt "Do you want to run the Calibre uninstaller (${GREEN}$calibre_uninstaller${RESET}) now? (y/N)" confirm_calibre_uninstall "true"
        if [[ "$confirm_calibre_uninstall" =~ ^[Yy]$ ]]; then
            print_status "Running Calibre uninstaller (may require root password and interaction)..."
            if sudo "$calibre_uninstaller"; then
                calibre_uninstalled=true
                print_status "Calibre uninstallation script finished."
            else
                print_error "Calibre uninstallation failed or was cancelled. Manual removal may be necessary."
            fi
        fi
    fi
    # -----------------------------------------

    # Make sure package manager is detected
    # fix: PKG_AUTOREMOVE_ARRAY: bad array subscript
    # TODO: consider check for $DISTRO_FAMILY
    if [[ -z "$PKG_MANAGER" ]]; then
        detect_distro_and_package_manager || {
            print_error "Could not detect a supported package manager. Aborting."
            exit 1
        }
    fi

    # # --- Explicit removal of ACW dependencies ---
    # print_status "Preparing to purge Autocaliweb dependencies..."
    # read -r -p "Do you want to remove these packages now? (y/N): " confirm_remove
    # if [[ "$confirm_remove" =~ ^[Yy]$ ]]; then
    #     if uninstall_packages_for_distro; then
    #         packages_removed=true
    #     fi
    # else
    #     print_warning "Skipping explicit package removal."
    # fi
    # # --- Autoremove orphaned packages ---
    # print_status "Running autoremove: ${autoremove_cmd[*]}"
    # "${autoremove_cmd[@]}" || print_warning "Autoremove failed"
    # # Autoremove
    # if [[ -n "${PKG_AUTOREMOVE_ARRAY[$PKG_MANAGER]}" ]]; then
    #     read -r -p "Do you also want to autoremove orphaned dependencies? (y/N): " confirm_auto
    #     if [[ "$confirm_auto" =~ ^[Yy]$ ]]; then
    #         IFS=' ' read -r -a autoremove_cmd <<<"${PKG_AUTOREMOVE_ARRAY[$PKG_MANAGER]}"
    #         print_status "Running autoremove: ${autoremove_cmd[*]}"
    #         if "${autoremove_cmd[@]}"; then
    #             packages_cleaned=true
    #         else
    #             print_warning "Autoremove failed"
    #         fi
    #     fi
    # fi
    # # ------------------------------------------------

    # --- Reporting ACW dependencies ---
    print_status "Identifying Autocaliweb dependencies for manual cleanup..."

    # We no longer ask "Do you want to remove?" because we won't do it.
    # We simply proceed to generate the list.
    uninstall_packages_for_distro

    # --- Reporting Orphaned Packages (Autoremove) ---
    if [[ -n "${PKG_AUTOREMOVE_ARRAY[$PKG_MANAGER]}" ]]; then
        local orphan_cmd_template="${PKG_AUTOREMOVE_ARRAY[$PKG_MANAGER]}"
        local final_orphan_cmd_array=() # Use an array for safe manipulation
        local final_orphan_cmd_string=""

        print_status "Identifying orphan cleanup command..."

        # 1. Sanitize the command based on PKG_MANAGER
        if [ "$PKG_MANAGER" = "pacman" ]; then
            # Remove --noconfirm flag from pacman command
            final_orphan_cmd_string="${orphan_cmd_template//--noconfirm/}"
        elif [ "$PKG_MANAGER" = "apk" ]; then
            # Remove --purge flag from apk command
            final_orphan_cmd_string="${orphan_cmd_template//--purge/}"
        else
            # For dnf, apt, zypper, etc., use the template command
            final_orphan_cmd_string="$orphan_cmd_template"
        fi

        # Convert the string back into an array to safely remove the -y flag
        IFS=' ' read -r -a final_orphan_cmd_array <<<"$final_orphan_cmd_string"

        # Remove '-y' flag if present (Handles dnf, apt-get, yum)
        final_orphan_cmd_array=("${final_orphan_cmd_array[@]/ -y/}")
        final_orphan_cmd_array=("${final_orphan_cmd_array[@]/-y/}")
        # Rejoin the array into a clean string for printing
        final_orphan_cmd_string="${final_orphan_cmd_array[*]}"

        # Prepend sudo and print the command
        print_warning "AUTOMATIC ORPHAN REMOVAL DISABLED FOR SYSTEM SAFETY."
        print_status "To remove potentially orphaned packages, please review and run the following command manually:"

        printf "%s\n" "${BOLD}${CYAN}sudo ${final_orphan_cmd_string}${RESET}"
        echo ""
    fi

    # Clean up environment variables from /etc/environment
    print_status "Cleaning up environment variables from /etc/environment..."
    sed -i '/^ACW_INSTALL_DIR=/d' /etc/environment
    sed -i '/^ACW_CONFIG_DIR=/d' /etc/environment
    sed -i '/^ACW_USER=/d' /etc/environment
    sed -i '/^ACW_GROUP=/d' /etc/environment
    sed -i '/^LIBRARY_DIR=/d' /etc/environment
    sed -i '/^INGEST_DIR=/d' /etc/environment
    sudo rm -f /etc/autocaliweb/environment

    print_status "Autocaliweb uninstallation completed!"
    echo
    echo "=== Uninstallation Summary ==="
    echo "✅ All systemd services stopped and removed."

    if [ "$data_deleted" = true ]; then
        echo "✅ All core application data files removed."
    else
        echo "⚠️  Core application data files preserved."
    fi

    if [ "$kepubify_removed" = true ]; then
        echo "✅ Kepubify executable removed."
    else
        echo "⚠️  Kepubify executable preserved."
    fi

    if [ "$calibre_uninstalled" = true ]; then
        echo "✅ Calibre uninstallation script completed."
    else
        echo "⚠️  Calibre uninstaller not run or failed."
    fi

    if [[ "$packages_removed" = true ]]; then
        echo "✅ Core dependencies removed"
    else
        echo "⚠️  Core dependencies not removed"
    fi

    if [ "$packages_cleaned" = true ]; then
        echo "✅ Orphan packages cleaned."
    else
        echo "⚠️  Orphan packages cleanup was skipped or failed."
    fi

    echo "✅ Lock files and environment variables cleaned up."
    echo
    echo "Autocaliweb has been successfully uninstalled from your system."
}

# ------------------------------------------------------------------------
# Detect where the script is running from
# ------------------------------------------------------------------------
# If the user download and extract autocaliweb then run the script from
# that folder, we need to know the script location to use the source.
# Other than that we don't need the location.
detect_script_location() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    print_verbose "Script is running from: $script_dir"

    # Check if we're running from within an existing autocaliweb
    # installation / source check parent directory
    local parent_dir
    parent_dir="$(dirname "$script_dir")"
    if [[ -f "$parent_dir/requirements.txt" && -f "$parent_dir/cps.py" &&
        -f "$parent_dir/cps/__init__.py" ]]; then
        print_verbose "Script is running from scripts/ subdirectory of autocaliweb"
        SCRIPT_SOURCE_DIR="$parent_dir"
        return 0
    fi

    # Not running from source directory
    print_verbose "Script location: Running standalone (not from source)"
    SCRIPT_SOURCE_DIR=""
    return 0
}

# Function to initialize script execution environment
init_environment() {
    is_running_as_root "$@"
    set_log_file_permissions
    if [ "$UNINSTALL_MODE" != "1" ]; then
        print_status "Autocaliweb Manual Installation Script ($VERSION_NUMBER) Starting..."
    else
        print_status "Autocaliweb Manual Uninstallation (V: $VERSION_NUMBER) Starting..."
    fi
    if [ "$LOG_FILE" = "" ]; then
        print_status "Log file:            Disabled"
    else
        print_status "Log file:            $LOG_FILE"
    fi
    # --- General options ---
    print_status "Verbose mode:        $(bool_to_status "$VERBOSE")"
    print_status "Debug mode:          $(bool_to_status "$DEBUG_MODE")"
    print_status "Accept all:          $(bool_to_status "$ACCEPT_ALL")"

    # --- Installation control ---
    print_status "Skip updates:        $(bool_to_status "${SKIP_UPDATE:-0}")"
    print_status "Uninstall mode:      $(bool_to_status "$UNINSTALL_MODE")"
    print_status "Headless mode:       $(bool_to_status "$IS_HEADLESS")"
    print_status "Allow low space:     $(bool_to_status "ALLOW_LOW_SPACE")"

    detect_headless_mode
}

detect_and_classify_installation() {

    if [[ -f "/etc/systemd/system/autocaliweb.service" ]]; then
        print_status "Found existing installation (systemd service exists)"
        EXISTING_INSTALLATION=true
        IS_UPDATE=true
        # We found install, is it modern or legacy?
        if [[ -f "/etc/autocaliweb/environment" ]]; then
            # modern install ... Update
            IS_LEGACY_MIGRATION=false
        else
            # legacy install.. Migrate then Update
            IS_LEGACY_MIGRATION=true
        fi
    else
        # new install ... Install
        EXISTING_INSTALLATION=false
        IS_LEGACY_MIGRATION=false
        IS_UPDATE=false
    fi

    if [[ "$IS_UPDATE" == true ]]; then
        if [[ "$IS_LEGACY_MIGRATION" == true ]]; then
            CURR_INSTALL_PATH="$LEGACY_INSTALL_DIR"
        else
            CONFIG_LINE=$(grep "^ACW_INSTALL_DIR" /etc/autocaliweb/environment)
            CURR_INSTALL_PATH="${CONFIG_LINE#*=}"
        fi

        local is_git_repo=false
        print_verbose "Checking if installation directory is a git repository..."
        # GIT_CHECK_USER=$(check_if_git_repo "$CURR_INSTALL_PATH")
        check_if_git_repo "$CURR_INSTALL_PATH"
        if [[ "$GIT_CHECK_USER" == "" ]]; then
            is_git_repo=false
        else
            is_git_repo=true
        fi
    else
        check_if_git_repo "$SCRIPT_SOURCE_DIR"
        if [[ "$GIT_CHECK_USER" == "" ]]; then
            is_git_repo=false
        else
            is_git_repo=true
        fi
    fi

    # Check for template files
    print_verbose "Checking for presence of existing template files..."
    local has_template=false
    if [ -f "$INSTALL_DIR/library/app.db" ]; then
        has_template=true
    fi

    # Determine scenario based on both conditions
    if [ "$is_git_repo" = "true" ]; then
        if [ "$has_template" = "true" ]; then
            SCENARIO="git_repo_with_template"
            print_status "Detected: Git repository installation with template files"
        else
            SCENARIO="git_repo_without_template"
            print_status "Detected: Git repository installation without template files"
        fi
    elif [ "$has_template" = "true" ]; then
        SCENARIO="extracted_with_template"
        print_status "Detected: Extracted installation with template files"
    elif [ -f "$INSTALL_DIR/requirements.txt" ]; then
        SCENARIO="extracted_without_template"
        print_status "Detected: Extracted source without template files"
    else
        # Special case: check if the source extracted outside the install directory.
        detect_script_location
        if [[ "$SCRIPT_SOURCE_DIR" == "" ]]; then
            SCENARIO="no_source"
            print_status "Detected: No source files, will download"
        else
            SCENARIO="outside_without_template"
        fi
    fi
    print_verbose "Final SCENARIO result: '$SCENARIO'"
    # echo "$SCENARIO" >&1
    # Return a single delimited string containing all the necessary variables
    # Format: SCENARIO|EXISTING_INSTALLATION|IS_LEGACY_MIGRATION|IS_UPDATE
    # IS_UPDATE=false
    # echo "${SCENARIO}|${EXISTING_INSTALLATION}|${IS_LEGACY_MIGRATION}|${IS_UPDATE}"

}

check_distro() {

    # disable log file, -dc should run successfully without root permission.
    LOG_FILE=""
    detect_distro_and_package_manager || exit 1
    show_distro_support_matrix
    echo
    check_system_requirements
    estimate_total_space_required "true"
    check_disk_space "${TOTAL_SPACE_REQUIRED}" "$INSTALL_DIR"
}

fix_python_packages() {
    print_status "Fixing python pcakges ..."
    # 1. rauth
    # goodreads depend on rauth 0.7.3 (https://pypi.org/project/rauth/, https://github.com/litl/rauth)
    # rauth is deprecated and not compatible with python 3.10+. Currently it flood the log with
    # "SyntaxWarning: invalid escape sequence" I created new version (rauth 0.7.4) compatable with python 3.10+
    # Until we found permanent fix, install rauth 0.7.4 from git directly.
    print_verbose "--- Starting Rauth Enforced Clean Reinstall ---"
    print_verbose "This will forcibly remove the old 0.7.3 version and install the Git version."
    # activate .venv
    # shellcheck disable=SC1091
    source "$INSTALL_DIR/.venv/bin/activate"
    # remove rauth 0.7.3
    print_verbose "Forcibly uninstalling ALL existing 'rauth' installations..."
    sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" uninstall rauth -y

    # Clear pip's cache. Activate for more AGGRESSIVE cleanig
    # print_verbose "Purging pip cache to remove stale build artifacts..."
    # sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" cache purge

    # REINSTALL the custom rauth version directly from the Git branch
    sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" install "rauth @ git+https://github.com/UsamaFoad/rauth.git@master"
    # Clear the Python bytecode cache to prevent old .pyc files from being loaded.
    print_verbose "Clearing Python bytecode cache..."
    find "$INSTALL_DIR"/.venv/ -type d -name "__pycache__" -exec rm -rf {} +
    find "$INSTALL_DIR"/.venv/ -type f -name "*.pyc" -delete
    print_verbose "--- Reinstallation and Cleanup Complete ---"
    print_verbose "The 'rauth' folder in site-packages should now contain only the patched files."

    # 2. scholarly
    # metadata depend on scholarly. scholarly shows SyntaxWarning: invalid escape sequence in the log.
    # crude but effective fix: search and replace the wrong escape sequence (add raw 'r' to the string)
    # _scholarly.py:312
    #    current : m = re.search("cites=[\d+,]*", object["citedby_url"])
    #    required: m = re.search(r"cites=[\d+,]*", object["citedby_url"])
    # use sed to search/replace the line. use -i to create backup file .bak
    print_verbose "--- Starting Scholarly Editing ---"
    local target_scholarly_file
    local LIB_DIR
    local PYTHON_VERSION_DIR_PATH
    local PYTHON_VERSION_DIR
    local TARGET_FILE

    LIB_DIR="${INSTALL_DIR}/.venv/lib/"
    PYTHON_VERSION_DIR_PATH=$(find "${LIB_DIR}" -maxdepth 1 -type d -name "python*" 2>/dev/null | head -n 1)
    TARGET_FILE="/scholarly/_scholarly.py"

    if [ -z "$PYTHON_VERSION_DIR_PATH" ]; then
        print_error "Could not find a Python version directory in $LIB_DIR, escape Scholarly Editing"
        return 0
    else
        PYTHON_VERSION_DIR=$(basename "$PYTHON_VERSION_DIR_PATH")
    fi

    # ex: ${INSTALL_DIR}/.venv/lib/python3.13/site-packages/scholarly/_scholarly.py
    target_scholarly_file="${LIB_DIR}${PYTHON_VERSION_DIR}/site-packages${TARGET_FILE}"
    print_verbose "Editing file: $target_scholarly_file"
    sed -i.bak 's/re.search("cites=/re.search(r"cites=/g' "$target_scholarly_file"
    print_verbose "--- Scholarly Edit Completed ---"

    # Redundant: the message for the update related to the OS not the venv
    # # Upgrade pip and setuptools
    # print_status "Upgrading pip and setuptools..."
    # sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" install --upgrade pip setuptools
    deactivate

    print_status "Fixing python pcakges completed."
    return 0
}

trap cleanup_on_failure ERR

# Main installation process
main() {

    # Setup
    parse_arguments "$@"
    set_debug

    if [[ "${DISTRO_CHECK_ONLY:-0}" -eq 1 ]]; then
        check_distro
        exit 0
    fi

    init_environment "$@"

    if [ "$UNINSTALL_MODE" = "1" ]; then
        uninstall_autocaliweb
        exit 0
    fi

    detect_and_classify_installation

    if [[ "$IS_LEGACY_MIGRATION" == true ]]; then
        migrate_legacy_venv
        detect_existing_legacy_installation
    fi

    check_dependencies
    check_system_requirements

    print_verbose "Detected SCENARIO: $SCENARIO"

    estimate_total_space_required

    check_disk_space "${TOTAL_SPACE_REQUIRED}" "$INSTALL_DIR" "Initial installation"

    if [ "$IS_UPDATE" == true ]; then
        # Stop services before update & before handling services's user
        # and before cleanup
        stop_acw_services
    fi

    if [ "$EXISTING_INSTALLATION" = true ]; then
        cleanup_lock_files
    fi

    prepare_service_environment
    create_acw_directories

    install_system_deps

    check_directories "$SCENARIO"
    setup_autocaliweb

    # Check for dependency conflicts
    if ! check_python_dependencies; then
        print_status "Attempting to resolve dependency conflicts..."
        # shellcheck disable=SC1091
        source "$INSTALL_DIR/.venv/bin/activate"
        "$INSTALL_DIR/.venv/bin/pip" install -r requirements.txt --force-reinstall --no-deps
        "$INSTALL_DIR/.venv/bin/pip" install -r requirements.txt # Reinstall with dependencies
    fi

    install_external_tools
    make_koreader_plugin
    setup_configuration
    ensure_calibre_library
    initialize_databases "$SCENARIO"
    set_permissions

    # Always create the services
    create_systemd_service
    create_acw_ingest_service
    create_auto_zipper_service
    create_metadata_change_detector

    setup_permanent_environment_variables

    # Only run auto_library for new installations
    # auto_library.py can't run before exporting environment variable.
    # without env python will serach for app.db inside /app/autocaliweb/library
    if [[ "$SCENARIO" =~ "_with_" ]] && [ "$EXISTING_INSTALLATION" != true ]; then
        run_auto_library
    fi

    # scholarly & rauth are optional requirements, if no optional-requirements installed no fix needed.
    # Fix: sed: can't read .../_scholarly.py: No such file or directory
    if [ "$FIX_PYTHON_PAC" = true ]; then
        fix_python_packages
    fi

    start_acw_services

    set_acw_permissions
    verify_installation
    verify_services
    create_startup_script

    print_status "Installation completed successfully!"
    install_flask_limiter
    echo
    echo " ====== Autocaliweb Manual Installation Complete ====== "
    echo
    echo "🚀 Services Status:"
    echo "   • autocaliweb.service - Main web application"
    echo "   • acw-ingest-service.service - Automatic File Importer"
    echo "   • acw-auto-zipper.service - Daily backup archiver"
    echo "   • metadata-change-detector.service - Background Processing Engine"
    echo
    echo "📋 Next Steps:"
    echo "1. Verify services are running:"
    echo "   sudo systemctl status autocaliweb"
    echo "   sudo systemctl status acw-ingest-service"
    echo "   sudo systemctl status acw-auto-zipper"
    echo "   sudo systemctl status metadata-change-detector"
    echo
    echo "2. Access web interface: http://localhost:8083"
    echo "   Default credentials: admin/admin123"
    echo
    echo "3. Configure Calibre library path in Admin → Database Configuration"
    echo "   Point to: $CALIBRE_LIB_DIR (must contain metadata.db)"
    echo
    echo "📁 Key Directories:"
    echo "   • Application: $INSTALL_DIR"
    echo "   • Configuration: $CONFIG_DIR"
    echo "   • Calibre Library: $CALIBRE_LIB_DIR"
    echo "   • Book Ingest: $INGEST_DIR (link created at: ${USER_HOME})"
    echo
    echo "🔧 Troubleshooting:"
    echo "   • View logs: sudo journalctl -u autocaliweb -f"
    echo "   • View manual install log: cat $LOG_FILE | more"
    echo "   • Check service status: sudo systemctl status <service-name>"
    echo "   • Manual start: $INSTALL_DIR/start_autocaliweb.sh"
    echo
    echo "⚠️  Important Notes:"
    echo "   • Ensure $REAL_USER is logged out/in to use group permissions"
    echo "   • Virtual environment is at: $INSTALL_DIR/.venv/"
    echo "   • All Python scripts use .venv automatically via systemd services"
    if [[ "$UNRAR_PATH" = "" ]]; then
        echo "   • ${BOLD}Optional Unrar${RESET}: To enable processing and extraction of RAR archives, you must manually install your preferred 'unrar' utility (e.g., 'unrar' or 'unrar-free').
        After install add it from Admin  → Edit Basic Configuration → External binaries  → Location of Unrar binary"
    fi
    echo
    if [ -f "$CONFIG_DIR/app.db" ]; then
        echo "✅ Database initialized successfully"
    else
        echo "⚠️  Database will be created on first run"
    fi
}

# Run main function
main "$@"
# ------------------------
# Successful deployment
# ------------------------
# Ubuntu 25.04
# Debian: Xfce (13.0.0, 12.5.0, 12.10.0, 12.0.0)
# openSUSE-Tumbleweed version = 20251007
# Fedora 42 Xfce
# CentOS Stream 10 (Coughlan)
# RHEL Red Hat Enterprise Linux 10.0 (Coughlan) (rhel 10.0)
# Arch ARCH_202510
# openSUSE Leap 15.6 (opensuse-leap 15.6)
# openSUSE Tumbleweed (opensuse-tumbleweed 20251007)
# SLES SUSE Linux Enterprise Server 15 SP7 (sles 15.7)
# ------------------------