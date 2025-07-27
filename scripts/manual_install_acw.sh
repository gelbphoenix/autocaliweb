#!/bin/bash
# manual_install_acw.sh - Run this as root
# v.2.0
# Copyright (C) 2025 Autocaliweb
# First creator UsamaFoad <usamafoad@gmail.com>

set -e
trap cleanup_on_failure ERR

VERBOSE="${VERBOSE:-0}"
LOG_FILE="${LOG_FILE:-/tmp/manual_install_acw.log}"
UNINSTALL_MODE="${UNINSTALL_MODE:-0}"
ACCEPT_ALL="${ACCEPT_ALL:-0}"

# Configuration
INSTALL_DIR="/app/autocaliweb"
CONFIG_DIR="/config"
CALIBRE_LIB_DIR="/calibre-library"
INGEST_DIR="/acw-book-ingest"
SERVICE_USER="abc"
SERVICE_GROUP="abc"

# Get the actual user who called sudo
REAL_USER=${SUDO_USER:-$USER}
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[$(date)] INFO: $1" >> "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[$(date)] WARNING: $1" >> "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    [ -n "$LOG_FILE" ] && echo "[$(date)] ERROR: $1" >> "$LOG_FILE"
}

# ==== Argument parser ====
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --yes|--Yes|-y)
            ACCEPT_ALL=1
            shift
            ;;
        --log=*)
            LOG_FILE="${1#*=}"
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --uninstall)
            UNINSTALL_MODE=1
            shift
            ;;
        --help)
            echo "Usage: $0 [--log=/path/to/logfile] [--verbose] [--uninstall] [--yes] [--help]"
            echo "  --log=PATH     Specify log file location (default /tmp/manual_install_acw.log)"
            echo "                 Set to empty string \"\" to disable logging"
            echo "  --verbose      Enable verbose output"
            echo "  --uninstall    Run the uninstaller to remove Autocaliweb partially or completely."
            echo "  --yes          Accept all prompts automatically. Some options still need your answer."
            echo "                 Does not work with the uninstall mode."
            echo "  --help         Shows this help message."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help to see available options."
            exit 1
            ;;
    esac
done

echo "=== Autocaliweb Manual Install Script ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

print_status "Log file: $LOG_FILE"
print_status "Verbose mode: $VERBOSE"
print_status "Accept all: $ACCEPT_ALL"
print_status "Uninstall mode: $UNINSTALL_MODE"

# Checking required dependencies
check_dependencies() {
    print_status "Checking required dependencies..."
    # update moved here to avoid calling it twice with install_system_deps
    if [ "$VERBOSE" = "1" ]; then
        apt-get update
    else
        apt-get update >/dev/null 2>&1
    fi

    local missing_deps=()

    # List of commands that should be present on the system during Install
    for cmd in curl git python3 sqlite3 tar zip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "The following core dependencies are missing: ${missing_deps[*]}"
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-accepting install missing dependencies (--yes flag provided)"
            REPLY="y"
        else
            read -p "Do you want to attempt to install these missing dependencies now? (y/n): " -n 1 -r
            echo # empty line
        fi
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            print_status "Attempting to install missing dependencies..."
            install_system_deps "${missing_deps[@]}"
            # After installation, re-check if they are now available
            local recheck_missing_deps=()
            for cmd in curl git python3 sqlite3 tar zip; do
                if ! command -v "$cmd" >/dev/null 2>&1; then
                    recheck_missing_deps+=("$cmd")
                fi
            done
            if [ ${#recheck_missing_deps[@]} -ne 0 ]; then
                print_error "Failed to install some core dependencies: ${recheck_missing_deps[*]}"
                print_error "Please install them manually and re-run the script."
                exit 1
            else
                print_status "All core dependencies are now installed."
            fi
        else
            print_error "Installation aborted. Missing core dependencies: ${missing_deps[*]}"
            print_error "Please install them manually and re-run the script."
            exit 1
        fi
    else
        print_status "All core dependencies found."
    fi
}

check_disk_space() {
    local required_space_mb=1024  # 1GB minimum
    local available_space_mb=$(df /app | awk 'NR==2 {print int($4/1024)}')
    if [ "$available_space_mb" -lt "$required_space_mb" ]; then
        print_error "Insufficient disk space. Required: ${required_space_mb}MB, Available: ${available_space_mb}MB"
        exit 1
    fi
    print_status "Disk space check passed: ${available_space_mb}MB available"
}

check_system_requirements() {
    if ! systemctl --version >/dev/null 2>&1; then
        print_error "systemd is required but not found"
        exit 1
    fi
    # Check Python version
    local python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)"; then
        print_error "Python 3.8+ required, found $python_version"
        exit 1
    fi
}

detect_existing_installation() {
    EXISTING_INSTALLATION=false

    # Check for existing database with user data
    if [ -f "$CONFIG_DIR/app.db" ] && [ -s "$CONFIG_DIR/app.db" ]; then
        # Verify it's not just an empty template
        local table_count=$(sqlite3 "$CONFIG_DIR/app.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
        if [ "$table_count" -gt 5 ]; then
            EXISTING_INSTALLATION=true
            print_status "Existing installation detected with user data"
        fi
    fi
    # Check for existing services
    if systemctl list-unit-files | grep -q "autocaliweb.service"; then
        EXISTING_INSTALLATION=true
        print_status "Existing systemd services detected"
    fi
    if [ "$EXISTING_INSTALLATION" = true ]; then
        print_warning "This appears to be an update of an existing installation"
        print_status "User data and configuration will be preserved"
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-accepting update (--yes flag provided)"
            REPLY="y"
        else
            read -p "Continue with update? (y/n): " -n 1 -r
            echo
        fi
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            print_error "Update cancelled by user"
            exit 1
        fi
    fi
}

stop_acw_services() {
    if [ "$EXISTING_INSTALLATION" = true ]; then
        print_status "Stopping services for update..."
        systemctl stop autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector 2>/dev/null || true
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

detect_installation_SCENARIO() {
    SCENARIO=""

    # SCENARIO 2: Git repository (cloned)
    if git -C "$INSTALL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        SCENARIO="git_repo"
        print_status "Detected: Git repository installation"
        backup_existing_data
    # SCENARIO 2: Has template (extracted with library/)
    elif [ -f "$INSTALL_DIR/library/app.db" ]; then
        SCENARIO="with_template"
        print_status "Detected: Installation with template files"
    # SCENARIO 1 & 3: No source or extracted without template
    elif [ ! -f "$INSTALL_DIR/requirements.txt" ]; then
        SCENARIO="no_source"
        print_status "Detected: No source files, will download"
    else
        SCENARIO="extracted_no_template"
        print_status "Detected: Extracted source without template"
    fi

    echo "$SCENARIO" # <<< CRITICAL: Echo the result so it can be captured
}

backup_existing_data() {
    local user_home
    user_home="$(eval echo "~$REAL_USER")"
    if [ ! -d "$user_home" ]; then
        print_error "User home directory not found for $REAL_USER"
        return 1
    fi
    if [ -f "$CONFIG_DIR/app.db" ]; then
        local backup_file="$user_home/app.db.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_DIR/app.db" "$backup_file"
        chown "$REAL_UID:$REAL_GID" "$backup_file"
        print_status "app.db: Database backed up to: $backup_file"
    fi
    if [ -f "$CONFIG_DIR/acw.db" ]; then
        local backup_file="$user_home/acw.db.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_DIR/acw.db" "$backup_file"
        chown "$REAL_UID:$REAL_GID" "$backup_file"
        print_status "acw.db: Database backed up to: $backup_file"
    fi
    if [ -f "/calibre-library/metadata.db" ]; then
        local backup_file="$user_home/metadata.db.backup.$(date +%Y%m%d_%H%M%S)"
        cp "/calibre-library/metadata.db" "$backup_file"
        chown "$REAL_UID:$REAL_GID" "$backup_file"
        print_status "metadata.db: Database backed up to: $backup_file"
    fi
}

# Create dedicated user and group if they don't exist
create_service_user() {
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        print_status "Creating system user '$SERVICE_USER' and group '$SERVICE_GROUP'..."
        adduser "$SERVICE_USER" --system --no-create-home --group
    else
        print_status "User '$SERVICE_USER' already exists."
    fi
}

# Create main directories
create_acw_directories() {
    print_status "Creating directories for user: $SERVICE_USER ($SERVICE_USER:$SERVICE_GROUP)"
    # setgid bit 2 ensures new files/subdirectories automatically inherit the group of the parent.
    # Directories with restrictive permissions (2755) - no group write
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2755 /app/autocaliweb
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2755 /config
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2755 /config/.config/calibre/plugins
    # Directories with relaxed permissions (2775) - group write needed
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /calibre-library
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /acw-book-ingest
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /config/processed_books/converted
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /config/processed_books/imported
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /config/processed_books/failed
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /config/processed_books/fixed_originals
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /config/log_archive
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /config/.acw_conversion_tmp
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /app/autocaliweb/metadata_change_logs
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 2775 /app/autocaliweb/metadata_temp
    print_status "Directory structure created successfully!"
}

# Cleanup like root/etc/s6-overlay/s6-rc.d/acw-init/run
cleanup_lock_files() {
    if [ "$EXISTING_INSTALLATION" = true ]; then
        declare -a lockFiles=("ingest_processor.lock" "convert_library.lock" "cover_enforcer.lock" "kindle_epub_fixer.lock")
        print_status "Checking for leftover lock files..."
        counter=0
        for f in "${lockFiles[@]}"; do
            if [ -f "/tmp/$f" ]; then
                print_status "Removing leftover $f..."
                rm "/tmp/$f"
                let counter++
            fi
        done
        print_status "$counter lock file(s) removed."
    fi
}

# Configure user and plugins
configure_user_and_plugins() {

    # Add the actual user to abc group (-a append)
    usermod -a -G $SERVICE_GROUP $REAL_USER
    # Add the abc user to the actual user group
    usermod -a -G $REAL_GID $SERVICE_USER

    # If Calibre exists copy the plugins otherwise continue
    cp -Ra /home/$REAL_USER/.config/calibre/plugins/. /config/.config/calibre/plugins/ 2>/dev/null || true
    ln -sf /config/.config/calibre/plugins /config/calibre_plugins

    print_status "User groups and Calibre plugins configured successfully!"
}

# Install system or core dependencies
install_system_deps() {
    print_status "Installing system dependencies..."

    local packages_to_install=()
    # Check if arguments were passed to the function (core dependencies)
    if [ "$#" -gt 0 ]; then
        # If arguments are provided, use them as the list of packages
        packages_to_install=("$@")
        print_status "Installing specific dependencies: ${packages_to_install[*]}"
    else
        # If no arguments, use the full default list
        print_status "Installing all default system dependencies..."
        packages_to_install=(
            python3-dev python3-pip python3-venv
            build-essential libldap2-dev libssl-dev libsasl2-dev
            imagemagick ghostscript
            libmagic1 libxi6 libxslt1.1
            libxtst6 libxrandr2 libxkbfile1
            libxcomposite1 libopengl0 libnss3
            libxkbcommon0 libegl1 libxdamage1
            libgl1 libglx-mesa0 xz-utils
            sqlite3 xdg-utils inotify-tools
            netcat-openbsd binutils curl wget
        )
    fi
    # Use the constructed array for installation
    apt-get install -y --no-install-recommends "${packages_to_install[@]}"
    if [ $? -eq 0 ]; then
        print_status "System dependencies installed successfully."
    else
        print_error "Failed to install system dependencies."
        # This might be too aggressive to exit here, as check_dependencies will re-check.
        return 1 # Return a non-zero exit code to indicate failure
    fi
}

# Helper function to compare versions (v1 < v2)
# Returns 0 if v1 is strictly less than v2, 1 otherwise
version_lt() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ] && [ "$1" != "$2" ]
}

check_directories() {
    local current_scenario="$1" # Capture the first argument passed to this function
    print_status "Checking directory structure..."

    # Check if main directories exist
    if [ ! -d "$INSTALL_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
        print_error "Required directories not found."
        exit 1
    fi
    # Check if Autocaliweb source exists (by checking for requirements.txt)
    if [ ! -f "$INSTALL_DIR/requirements.txt" ]; then
        print_status "Autocaliweb source not found. Downloading latest release..."
        download_and_extract_autocaliweb_source
    else
        # Autocaliweb source exists, ask user if they want to update
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-accepting update (--yes flag provided)"
            REPLY="y"
        else
            read -p "Autocaliweb source found. Do you want to check for and apply updates? (y/n): " -n 1 -r
            echo # empty line
        fi
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            print_status "Checking for Autocaliweb updates..."
            # Check if INSTALL_DIR is a Git repository
            if [ "$current_scenario" = "git_repo" ]; then
                print_status "Autocaliweb is a Git repository. Attempting to pull latest changes..."
                (
                    cd "$INSTALL_DIR" || exit 1 # Change to install dir, exit if failed
                    git pull origin master
                )
                if [ $? -eq 0 ]; then
                    print_status "Git repository updated successfully."
                else
                    print_error "Failed to pull updates from Git repository."
                    # What to do after failed git pull?
                    echo
                    print_warning "What would you like to do?"
                    echo "  [C] Continue installation with existing (potentially outdated) source code."
                    echo "  [R] Re-download the latest release (will overwrite existing files, ignoring Git status)."
                    echo "  [X] Exit installation."
                    read -p "Enter your choice (C/R/X): " -n 1 -r
                    echo # empty line
                    case "$REPLY" in
                        [Cc]* )
                            print_warning "Continuing installation with existing source code."
                            ;;
                        [Rr]* )
                            print_status "Attempting to re-download latest release..."
                            download_and_extract_autocaliweb_source
                            ;;
                        [Xx]* )
                            print_error "Installation aborted by user."
                            exit 1
                            ;;
                        * )
                            print_error "Invalid choice. Aborting installation."
                            exit 1
                            ;;
                    esac
                fi
            else
                # Not a Git repository, check versions before re-downloading
                local CURRENT_ACW_VERSION=""
                if [ -f "/app/ACW_RELEASE" ]; then
                    CURRENT_ACW_VERSION=$(cat "/app/ACW_RELEASE")
                fi

                local LATEST_ACW_RELEASE=$(curl -s https://api.github.com/repos/gelbphoenix/autocaliweb/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
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
            fi
        else
            print_status "Skipping Autocaliweb source update."
        fi
    fi

    # Verify ownership (still crucial after any source manipulation)
    # This might be redundant if ownership is set by install -d -o, but good as a final check.
    # If the filesystem is mounted read-only, or there are specific immutable flags we will not get the write permission.
    if [ ! -w "$INSTALL_DIR" ] || [ ! -w "$CONFIG_DIR" ]; then
        print_error "Insufficient permissions for required directories."
        exit 1
    fi
    print_status "Directory structure verified"
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    local attempt=1

    local curl_opts="-L --connect-timeout 30 --max-time 300"
    if [ "$VERBOSE" = "1" ]; then
        curl_opts="$curl_opts"          # verbose: no -sS
    else
        curl_opts="-sS $curl_opts"      # silent but show errors
    fi
    while [ $attempt -le $max_attempts ]; do
        print_status "Download attempt $attempt/$max_attempts..."
        if curl $curl_opts -o "$output" "$url"; then
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
    local AUTOCALIWEB_RELEASE=$(curl -s https://api.github.com/repos/gelbphoenix/autocaliweb/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    if [ -z "$AUTOCALIWEB_RELEASE" ]; then
        print_error "Failed to retrieve latest Autocaliweb release tag. Aborting source download."
        exit 1
    fi
    print_status "Downloading Autocaliweb $AUTOCALIWEB_RELEASE..."
    download_with_retry "https://github.com/gelbphoenix/autocaliweb/archive/refs/tags/${AUTOCALIWEB_RELEASE}.tar.gz" "/tmp/autocaliweb.tar.gz"
    if [ $? -ne 0 ]; then
        print_error "Failed to download Autocaliweb source. Aborting."
        exit 1
    fi
    print_status "Cleaning existing Autocaliweb source in $INSTALL_DIR before extraction (excluding scripts, *.db, *.lock, and venv)..."
    # Iterate over all items in INSTALL_DIR
    # Delete everything *except* the scripts & venv directories, and any *.db or .lock files
        for item in "$INSTALL_DIR"/* "$INSTALL_DIR"/.*; do
        if [ -e "$item" ] && \
           [ "$item" != "$INSTALL_DIR/venv" ] && \
           [ "$item" != "$INSTALL_DIR/scriptS" ] && \
           [[ ! "$item" =~ \.lock$ ]] && \
           [[ ! "$item" =~ \.db$ ]]; then
            rm -rf "$item"
        fi
    done
    tar xf /tmp/autocaliweb.tar.gz -C "$INSTALL_DIR" --strip-components=1
    if [ $? -ne 0 ]; then
        print_error "Failed to extract Autocaliweb source. Aborting."
        exit 1
    fi
    rm /tmp/autocaliweb.tar.gz
    print_status "Autocaliweb source downloaded and extracted successfully."
}

setup_autocaliweb() {
    print_status "Setting up Autocaliweb..."
    cd "$INSTALL_DIR"

    # Verify source code exists
    if [ ! -f "requirements.txt" ]; then
        print_error "Please ensure Autocaliweb source code is in $INSTALL_DIR"
        exit 1
    fi

    # Ask about optional dependencies upfront
    local use_optional=false
    if [ -f "optional-requirements.txt" ]; then
        if [ "$ACCEPT_ALL" = "1" ]; then
            print_status "Auto-installing optional dependencies (--yes flag provided)"
            use_optional=true
        else
            read -p "Do you want to install optional dependencies? (y/n): " install_optional
            if [[ "$install_optional" == "y" || "$install_optional" == "Y" ]]; then
                use_optional=true
            fi
        fi
    fi

    # Setup or update Python environment
    if [ "$EXISTING_INSTALLATION" = true ] && [ -d "venv" ]; then
        print_status "Updating existing Python environment..."
        source venv/bin/activate
    else
        print_status "Setting up fresh Python environment..."
        python3 -m venv venv
        source venv/bin/activate
    fi

    # Install pip-tools
    pip install -U pip wheel pip-tools

    # Install dependencies based on user preference
    if [ "$use_optional" = true ]; then
        # Try combined lock file first
        if [ -f "combined-requirements.lock" ]; then
            print_status "Installing core + optional dependencies from lock file..."
            pip-sync combined-requirements.lock
        else
            print_status "Generating combined requirements on-the-fly..."
            print_status "Please be patient, this process can take several minutes..."
            (cat requirements.txt; echo; cat optional-requirements.txt) > combined-requirements.txt
            if pip-compile --strip-extras combined-requirements.txt --output-file combined-requirements.lock; then
                pip-sync combined-requirements.lock
            else
                print_warning "Lock file generation failed, falling back to source files..."
                pip install -r requirements.txt -r optional-requirements.txt
            fi
            rm -f combined-requirements.txt
        fi
    else
        # Core dependencies only
        if [ -f "requirements.lock" ]; then
            print_status "Installing core dependencies from lock file..."
            pip-sync requirements.lock
        else
            print_status "Generating core requirements lock file..."
            print_status "Please be patient, this process can take few minutes..."
            if pip-compile --strip-extras requirements.txt --output-file requirements.lock; then
                pip-sync requirements.lock
            else
                print_warning "Lock file generation failed, falling back to requirements.txt..."
                pip install -r requirements.txt
            fi
        fi
    fi

    chown -R "$SERVICE_USER:$SERVICE_GROUP" venv
    print_status "Autocaliweb installed successfully"
}

check_python_dependencies() {
    if [ -d "$INSTALL_DIR/venv" ]; then
        print_status "Checking Python dependency health..."
        source "$INSTALL_DIR/venv/bin/activate"

        if ! pip check >/dev/null 2>&1; then
            print_warning "Python dependency conflicts detected:"
            pip check 2>&1 | head -10
            read -p "Attempt to fix conflicts? (y/n): " -n 1 -r
            echo
            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                return 1  # Signal that fixes are needed
            fi
        else
            print_status "Python dependencies are healthy"
        fi
    fi
    return 0
}

# Separate function for Calibre installation
install_calibre() {
    print_status "Installing Calibre..."
    mkdir -p /app/calibre
    CALIBRE_RELEASE=$(curl -s https://api.github.com/repos/kovidgoyal/calibre/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    CALIBRE_VERSION=${CALIBRE_RELEASE#v}
    CALIBRE_ARCH=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/')

    download_with_retry "https://download.calibre-ebook.com/${CALIBRE_VERSION}/calibre-${CALIBRE_VERSION}-${CALIBRE_ARCH}.txz" "/tmp/calibre.txz"
    tar xf /tmp/calibre.txz -C /app/calibre
    /app/calibre/calibre_postinstall
    rm /tmp/calibre.txz
    chown -R "$SERVICE_USER:$SERVICE_GROUP" /app/calibre
    echo "$CALIBRE_RELEASE" >/app/CALIBRE_RELEASE
}

# Separate function for Kepubify installation
install_kepubify() {
    print_status "Installing Kepubify..."
    KEPUBIFY_RELEASE=$(curl -s https://api.github.com/repos/pgaskin/kepubify/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    ARCH=$(uname -m | sed 's/x86_64/64bit/;s/aarch64/arm64/')

    download_with_retry "https://github.com/pgaskin/kepubify/releases/download/${KEPUBIFY_RELEASE}/kepubify-linux-${ARCH}" "/usr/bin/kepubify"
    chmod +x /usr/bin/kepubify
    echo "$KEPUBIFY_RELEASE" >/app/KEPUBIFY_RELEASE
}

make_koreader_plugin() {
    print_status "Creating ACWSync plugin for KOReader..."
    if [ -d "$INSTALL_DIR/koreader/plugins/acwsync.koplugin" ]; then
        # Delete the digest and plugin zip files if exists
        rm "$INSTALL_DIR/koreader/plugins/acwsync.koplugin/"*.digest 2>/dev/null || true
        rm "$INSTALL_DIR/koreader/plugins/koplugin.zip" 2>/dev/null || true
        cd "$INSTALL_DIR/koreader/plugins"
        print_status "Calculating digest of plugin files..."
        PLUGIN_DIGEST=$(find acwsync.koplugin -type f -exec sha256sum {} + | sha256sum | cut -d' ' -f1)
        print_status "Plugin digest: $PLUGIN_DIGEST"
        echo "Plugin files digest: $PLUGIN_DIGEST" > acwsync.koplugin/${PLUGIN_DIGEST}.digest
        echo "Build date: $(date)" >> acwsync.koplugin/${PLUGIN_DIGEST}.digest
        echo "Files included:" >> acwsync.koplugin/${PLUGIN_DIGEST}.digest
        find acwsync.koplugin -type f -name "*.lua" -o -name "*.json" | sort >> acwsync.koplugin/${PLUGIN_DIGEST}.digest
        zip -r koplugin.zip acwsync.koplugin/
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
        print_warning "Make sure $SERVICE_USER has ownership of Calibre folder"
        CALIBRE_PATH=$(dirname $(which ebook-convert 2>/dev/null || which calibre))
        # Create Calibre version file
        if command -v calibre >/dev/null 2>&1; then
            if calibre --version | head -1 | cut -d' ' -f3 | sed 's/)//' >/app/CALIBRE_RELEASE 2>/dev/null; then
                print_status "Calibre version file created successfully"
            else
                print_warning "Could not determine Calibre version, using 'Unknown'"
                echo "Unknown" >/app/CALIBRE_RELEASE
            fi
        else
            echo "Unknown" >/app/CALIBRE_RELEASE
        fi
        print_status "Using existing Calibre at: $CALIBRE_PATH"
    else
        read -p "Calibre not found. Install Calibre? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_calibre
        else
            print_warning "Skipping Calibre installation. You'll need to install it manually."
            echo "Unknown" >/app/CALIBRE_RELEASE
        fi
    fi

    # Check for existing Kepubify installation
    if command -v kepubify >/dev/null 2>&1; then
        print_status "Kepubify already installed, skipping installation"
        KEPUBIFY_PATH=$(which kepubify)
        kepubify --version | head -1 | cut -d' ' -f2 >/app/KEPUBIFY_RELEASE
        print_status "Using existing Kepubify at: $KEPUBIFY_PATH"
    else
        read -p "Kepubify not found. Install Kepubify? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_kepubify
        else
            print_warning "Skipping Kepubify installation. You'll need to install it manually."
            echo "Unknown" >/app/KEPUBIFY_RELEASE
        fi
    fi
}

create_app_db_programmatically() {
    print_status "Creating app.db programmatically with all required tables..."

    # Create a comprehensive Python script to initialize both databases
    cat > /tmp/init_app_db.py <<EOF
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
    if ! sudo -u "$SERVICE_USER" "$INSTALL_DIR/venv/bin/python" /tmp/init_app_db.py; then
        print_error "Database initialization failed. Check Python environment and permissions."
        print_error "Try running: sudo -u $SERVICE_USER $INSTALL_DIR/venv/bin/python -c 'import sys; print(sys.path)'"
        rm /tmp/init_app_db.py
        exit 1
    fi

    if [ $? -eq 0 ]; then
        print_status "app.db created successfully with all tables at $CONFIG_DIR/app.db"

        # Set proper ownership and permissions for the database file
        chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/app.db"
        chmod 664 "$CONFIG_DIR/app.db"  # Read/write for owner and group

        # Also ensure the directory has proper permissions
        chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR"
        chmod 2775 "$CONFIG_DIR"  # Directory needs execute permission

        print_status "Database permissions set correctly"

        # Verify the settings table exists
        if sudo -u "$SERVICE_USER" sqlite3 "$CONFIG_DIR/app.db" "SELECT name FROM sqlite_master WHERE type='table' AND name='settings';" | grep -q settings; then
            print_status "Settings table verified successfully"
        else
            print_error "Settings table was not created properly"
            rm /tmp/init_app_db.py
            exit 1
        fi
        rm /tmp/init_app_db.py
    else
        print_error "Failed to create app.db programmatically"
        rm /tmp/init_app_db.py
        exit 1
    fi
}

# Initialize databases with detected binary paths
initialize_databases() {
    print_status "Initializing databases..."

    # Detect binary paths
    KEPUBIFY_PATH=$(which kepubify 2>/dev/null || echo "/usr/bin/kepubify")
    EBOOK_CONVERT_PATH=$(which ebook-convert 2>/dev/null || echo "/usr/bin/ebook-convert")
    CALIBRE_BIN_DIR=$(dirname "$EBOOK_CONVERT_PATH")

    # First check if app.db already exists (SCENARIO 4 - existing installation)
    if [ -f "$CONFIG_DIR/app.db" ]; then
        print_status "Existing app.db found, preserving user data"
    else
        # No existing app.db, check if we have a template to copy from
        if [ -f "$INSTALL_DIR/library/app.db" ]; then
            print_status "Template app.db found, copying to $CONFIG_DIR"
            cp "$INSTALL_DIR/library/app.db" "$CONFIG_DIR/app.db"
            chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DIR/app.db"
            chmod 664 "$CONFIG_DIR/app.db"
        else
            print_warning "No template app.db found, creating database programmatically..."
            create_app_db_programmatically
        fi
    fi

    # Create symlink if needed
    if [ ! -f "$INSTALL_DIR/app.db" ] && [ -f "$CONFIG_DIR/app.db" ]; then
        ln -sf "$CONFIG_DIR/app.db" "$INSTALL_DIR/app.db"
        print_status "Symlink created from $CONFIG_DIR/app.db to $INSTALL_DIR/app.db"
    fi

    # Set correct binary paths in database
    if [ -f "$CONFIG_DIR/app.db" ]; then
        sqlite3 "$CONFIG_DIR/app.db" <<EOS
UPDATE settings SET
    config_kepubifypath='$KEPUBIFY_PATH',
    config_converterpath='$EBOOK_CONVERT_PATH',
    config_binariesdir='$CALIBRE_BIN_DIR',
    config_calibre_dir='$CALIBRE_LIB_DIR',
    config_logfile='/config/autocaliweb.log',
    config_access_logfile='/config/access.log'
WHERE 1=1;
EOS
        print_status "Binary paths configured in database"
    fi
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
Environment=PATH=$INSTALL_DIR/venv/bin:/usr/bin:/bin
Environment=PYTHONPATH=$INSTALL_DIR/scripts:$INSTALL_DIR
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
Environment=CALIBRE_DBPATH=$CONFIG_DIR
# ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/cps.py
# Unify app.db, If that works we could keep the app.db only on config
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/cps.py -p $CONFIG_DIR/app.db

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
        VERSION=$($INSTALL_DIR/venv/bin/python -c "import sys; sys.path.insert(0, '${INSTALL_DIR}'); from cps.constants import STABLE_VERSION; print(STABLE_VERSION)")
    else
        VERSION=$($INSTALL_DIR/venv/bin/python -c "import sys; sys.path.insert(0, '${INSTALL_DIR}'); from cps.constants import STABLE_VERSION; print(STABLE_VERSION)" 2>/dev/null)
    fi
    echo "$VERSION" > /app/ACW_RELEASE
    print_status "Configuration files updated"
}

ensure_calibre_library() {
    if [ ! -f "$CALIBRE_LIB_DIR/metadata.db" ]; then
        print_status "Creating minimal Calibre library..."
        mkdir -p "$CALIBRE_LIB_DIR"

        # Use calibredb if available, otherwise create minimal structure
        if command -v calibredb >/dev/null 2>&1; then
            calibredb --library-path="$CALIBRE_LIB_DIR" list >/dev/null 2>&1 || true
        else
            # Create minimal metadata.db structure
            sqlite3 "$CALIBRE_LIB_DIR/metadata.db" <<EOF
CREATE TABLE IF NOT EXISTS books (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS authors (id INTEGER PRIMARY KEY);
CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY);
EOF
        fi
        chown -R "$SERVICE_USER:$SERVICE_GROUP" "$CALIBRE_LIB_DIR"
        print_status "Calibre library initialized"
    fi
}

# Set permissions. Redundant but useful if the installation directory pre-exists or after failed install.
set_permissions() {
    print_status "Setting permissions..."

    # Set ownership for all directories
    chown -R $SERVICE_USER:$SERVICE_GROUP "$INSTALL_DIR" "$CONFIG_DIR" "$CALIBRE_LIB_DIR" "$INGEST_DIR" /app

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
source venv/bin/activate
python cps.py
EOF

    chmod +x "$INSTALL_DIR/start_autocaliweb.sh"
    print_status "Startup script created at $INSTALL_DIR/start_autocaliweb.sh"
}

# Create Ingest Service
create_acw_ingest_service() {
    print_status "Creating systemd service wrapper for acw-ingest-service..."

    # Create wrapper script
    tee ${INSTALL_DIR}/scripts/ingest_watcher.sh >/dev/null <<EOF
#!/bin/bash

INSTALL_PATH="${INSTALL_DIR}"
WATCH_FOLDER=\$(grep -o '"ingest_folder": "[^"]*' \${INSTALL_PATH}/dirs.json | grep -o '[^"]*\$')
echo "[acw-ingest-service] Watching folder: \$WATCH_FOLDER"

# Monitor the folder for new files
/usr/bin/inotifywait -m -r --format="%e %w%f" -e close_write -e moved_to "\$WATCH_FOLDER" |
while read -r events filepath ; do
    echo "[acw-ingest-service] New files detected - \$filepath - Starting Ingest Processor..."
    # Use the Python interpreter from the virtual environment
    \${INSTALL_PATH}/venv/bin/python \${INSTALL_PATH}/scripts/ingest_processor.py "\$filepath"
done
EOF

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
Environment=CALIBRE_DBPATH=/config
Environment=HOME=/config
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
    tee ${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh >/dev/null <<EOF
#!/bin/bash

# Source virtual environment
source ${INSTALL_DIR}/venv/bin/activate

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

    chmod +x ${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh
    chown ${SERVICE_USER}:${SERVICE_GROUP} ${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh

    # Create systemd service
    cat <<EOF | tee /etc/systemd/system/acw-auto-zipper.service
[Unit]
Description=Autocaliweb Auto Zipper Service
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment=CALIBRE_DBPATH=/config
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
create_metadata_change_detector(){
print_status "Creating systemd service for metadata-change-detector..."
    # Create wrapper script
    tee ${INSTALL_DIR}/scripts/metadata_change_detector_wrapper.sh >/dev/null <<EOF
#!/bin/bash
# metadata_change_detector_wrapper.sh - Wrapper for periodic metadata enforcement

# Source virtual environment
source ${INSTALL_DIR}/venv/bin/activate

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
                 ${INSTALL_DIR}/venv/bin/python  ${INSTALL_DIR}/scripts/cover_enforcer.py --log "\$log_name"

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
ExecStart=/bin/bash ${INSTALL_DIR}/scripts/metadata_change_detector_wrapper.sh
Restart=always
StandardOutput=journal
StandardError=journal
Environment=CALIBRE_DBPATH=$CONFIG_DIR
Environment=HOME=$CONFIG_DIR
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable metadata-change-detector
    print_status "Autocaliweb Metadata Change Detector service created and enabled"
}

run_auto_library() {
    print_status "Running auto library setup..."

    if ${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/scripts/auto_library.py; then
        print_status "Auto library setup completed successfully"
        return 0
    else
        exit_code=$?
        print_error "Auto library setup failed with exit code: $exit_code"
        return $exit_code
    fi
}

# It is over-kill but let's make sure the permissions are set
set_acw_permissions() {
    declare -a requiredDirs=("/config" "/calibre-library" "/app/autocaliweb")

    print_status "Setting ownership of directories to $SERVICE_USER:$SERVICE_GROUP..."

    for d in "${requiredDirs[@]}"; do
        if [ -d "$d" ]; then
            chown -R "$SERVICE_USER:$SERVICE_GROUP" "$d"
            chmod -R 2775 "$d"
            print_status "Set permissions for '$d'"
        fi
    done
}

start_acw_services() {
systemctl start autocaliweb
if systemctl is-active --quiet autocaliweb; then
    print_status "autocaliweb  service started"
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

verify_installation() {
    print_status "Verifying installation..."
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8083 2>/dev/null)

        if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
            print_status "✅ Web interface is responding"
            return 0
        fi

        print_status "Attempt $attempt/$max_attempts: HTTP $http_code, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done

    print_warning "⚠️  Web interface may not be ready yet. Check 'sudo journalctl -u autocaliweb -f'"
    return 1
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
    print_error "Installation failed, cleaning up..."

    # Stop and disable services
    systemctl stop autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector 2>/dev/null || true
    systemctl disable autocaliweb acw-ingest-service acw-auto-zipper metadata-change-detector 2>/dev/null || true

    # Remove service files
    rm -f /etc/systemd/system/autocaliweb.service
    rm -f /etc/systemd/system/acw-ingest-service.service
    rm -f /etc/systemd/system/acw-auto-zipper.service
    rm -f /etc/systemd/system/metadata-change-detector.service

    systemctl daemon-reload
}

uninstall_autocaliweb() {
    print_warning "This will completely remove Autocaliweb and all its data!"
    read -p "Are you sure you want to continue? Type 'yes' to confirm: " -r
    if [[ "$REPLY" != "yes" ]]; then
        print_status "Uninstall cancelled"
        exit 0
    fi
    # Stop and disable all Autocaliweb services
    print_status "Stopping and disabling Autocaliweb services..."

    # Main services
    sudo systemctl stop autocaliweb 2>/dev/null || true
    sudo systemctl disable autocaliweb 2>/dev/null || true

    sudo systemctl stop acw-ingest-service 2>/dev/null || true
    sudo systemctl disable acw-ingest-service 2>/dev/null || true

    sudo systemctl stop acw-auto-zipper 2>/dev/null || true
    sudo systemctl disable acw-auto-zipper 2>/dev/null || true

    sudo systemctl stop metadata-change-detector 2>/dev/null || true
    sudo systemctl disable metadata-change-detector 2>/dev/null || true

    # Remove systemd service files
    print_status "Removing systemd service files..."
    sudo rm -f /etc/systemd/system/autocaliweb.service
    sudo rm -f /etc/systemd/system/acw-ingest-service.service
    sudo rm -f /etc/systemd/system/acw-auto-zipper.service
    sudo rm -f /etc/systemd/system/metadata-change-detector.service

    # Reload systemd
    sudo systemctl daemon-reload

    print_status "Services stopped and removed successfully"

    # Backup
    read -p "Do you want to create backup for the databases? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        backup_existing_data
    fi

    # Ask about data deletion
    echo
    print_warning "The following will permanently delete ALL Autocaliweb data:"
    echo "  • Application files: /app/autocaliweb"
    echo "  • Configuration data: /config"
    echo "  • Calibre library: /calibre-library"
    echo "  • Book ingest folder: /acw-book-ingest"
    echo "  • User 'abc' and group 'abc'"
    echo

    read -p "Do you want to delete ALL data files? This cannot be undone! (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Removing all Autocaliweb data..."

        # Ask specifically about calibre-library
        read -p "Do you want to delete calibre-library too? This cannot be undone! (y/N): " -r calibre_reply
        if [[ $calibre_reply =~ ^[Yy]$ ]]; then
            sudo rm -rf /calibre-library
            print_status "Calibre library removed"
        else
            print_warning "Calibre library preserved at /calibre-library"
        fi

        # Remove application and data directories
        sudo rm -rf /app/autocaliweb
        sudo rm -rf /config
        sudo rm -rf /acw-book-ingest

        # Remove any remaining files in /app if it's empty
        if [ -d "/app" ] && [ -z "$(ls -A /app)" ]; then
            sudo rmdir /app
        fi

        print_status "Application data files removed"
    else
        print_warning "Data files preserved. You can manually remove them later if needed:"
        print_status "  sudo rm -rf /app/autocaliweb /config /calibre-library /acw-book-ingest"
    fi

    # Ask about user/group removal
    echo
    read -p "Do you want to remove the 'abc' user and group? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Removing 'abc' user and group..."

        # Remove user abc (this will also remove the group if no other users are in it)
        sudo userdel abc 2>/dev/null || true

        # Remove group abc if it still exists
        sudo groupdel abc 2>/dev/null || true

        print_status "User and group removed"
    else
        print_warning "User 'abc' and group 'abc' preserved"
    fi

    # Clean up any remaining lock files
    print_status "Cleaning up lock files..."
    sudo rm -f /tmp/ingest_processor.lock
    sudo rm -f /tmp/convert_library.lock
    sudo rm -f /tmp/cover_enforcer.lock
    sudo rm -f /tmp/kindle_epub_fixer.lock

    # Remove external tools if they were installed by the installer
    echo
    read -p "Do you want to remove Calibre and Kepubify if they were installed by Autocaliweb? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Removing external tools..."

        # Remove Calibre if installed in /app/calibre
        if [ -d "/app/calibre" ]; then
            sudo rm -rf /app/calibre
            print_status "Calibre removed from /app/calibre"
        fi

        # Remove Kepubify if installed in /usr/bin
        if [ -f "/usr/bin/kepubify" ] && [ -f "/app/KEPUBIFY_RELEASE" ]; then
            sudo rm -f /usr/bin/kepubify
            print_status "Kepubify removed from /usr/bin"
        fi

        # Remove version files
        sudo rm -f /app/CALIBRE_RELEASE
        sudo rm -f /app/KEPUBIFY_RELEASE
        sudo rm -f /app/ACW_RELEASE
    else
        print_warning "External tools preserved"
    fi

    print_status "Autocaliweb uninstallation completed!"
    echo
    echo "=== Uninstallation Summary ==="
    echo "✅ All systemd services stopped and removed"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "✅ All data files removed"
        echo "✅ User 'abc' and group removed"
    else
        echo "⚠️  Data files preserved"
        echo "⚠️  User 'abc' and group preserved"
    fi
    echo "✅ Lock files cleaned up"
    echo
    echo "Autocaliweb has been successfully uninstalled from your system."

}

# Main installation process
main() {
    print_status "Autocaliweb Manual Installation Starting..."
    if [ "$UNINSTALL_MODE" = "1" ]; then
        uninstall_autocaliweb
        exit 0
    fi
    check_dependencies
    detect_existing_installation
    check_disk_space
    check_system_requirements
    create_service_user
    create_acw_directories
    cleanup_lock_files
    configure_user_and_plugins

    # Stop services before update
    stop_acw_services

    # Only install system deps for new installations
    install_system_deps

    local install_SCENARIO=$(detect_installation_SCENARIO)
    check_directories "$install_SCENARIO"
    setup_autocaliweb

    # Check for dependency conflicts
    if ! check_python_dependencies; then
        print_status "Attempting to resolve dependency conflicts..."
        source "$INSTALL_DIR/venv/bin/activate"
        pip install -r requirements.txt --force-reinstall --no-deps
        pip install -r requirements.txt  # Reinstall with dependencies
    fi

    install_external_tools
    make_koreader_plugin
    setup_configuration
    ensure_calibre_library
    initialize_databases
    set_permissions

    # Only create services if they don't exist or if they've changed
    if [ "$EXISTING_INSTALLATION" != true ]; then
        create_systemd_service
        create_acw_ingest_service
        create_auto_zipper_service
        create_metadata_change_detector
    fi

    # Only run auto_library for new installations
    if [ "$install_SCENARIO" != "with_template" ] && [ "$EXISTING_INSTALLATION" != true ]; then
        run_auto_library
    fi

    # Use appropriate service start method
    if [ "$EXISTING_INSTALLATION" = true ]; then
        restart_acw_services
    else
        start_acw_services
    fi

    set_acw_permissions
    verify_installation
    verify_services
            create_startup_script


print_status "Installation completed successfully!"
echo
echo "=== Autocaliweb Manual Installation Complete ==="
echo
echo "🚀 Services Status:"
echo "   • autocaliweb.service - Main web application"
echo "   • acw-ingest-service.service - Book ingestion processor"
echo "   • acw-auto-zipper.service - Daily backup archiver"
echo "   • metadata-change-detector.service - automatically import downloaded ebooks"
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
echo "   • Book Ingest: $INGEST_DIR"
echo
echo "🔧 Troubleshooting:"
echo "   • View logs: sudo journalctl -u autocaliweb -f"
echo "   • View manual install log: cat $LOG_FILE | more"
echo "   • Check service status: sudo systemctl status <service-name>"
echo "   • Manual start: $INSTALL_DIR/start_autocaliweb.sh"
echo
echo "⚠️  Important Notes:"
echo "   • Ensure $REAL_USER is logged out/in to use group permissions"
echo "   • Virtual environment is at: $INSTALL_DIR/venv/"
echo "   • All Python scripts use venv automatically via systemd services"
echo
if [ -f "$CONFIG_DIR/app.db" ]; then
    echo "✅ Database initialized successfully"
else
    echo "⚠️  Database will be created on first run"
fi

}

# Run main function
main "$@"