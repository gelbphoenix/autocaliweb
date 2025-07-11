#!/bin/bash
# manual_install_acw.sh - Run this as root
#
# Copyright (C) 2025 Autocaliweb
# First creator UsamaFoad <usamafoad@gmail.com>

# TODO: add --dry-run option
# TODO: create a log file
set -e

echo "=== Autocaliweb Manual Installation Script ==="
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
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo "=== Autocaliweb Directory Preparation Script ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

# Create dedicated user and group if they don't exist
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "Creating system user '$SERVICE_USER' and group '$SERVICE_GROUP'..."
    # Group is redundant in the next command (one name in this mode).
    sudo adduser "$SERVICE_USER" --system --no-create-home --group # "$SERVICE_GROUP"
else
    print_status "User '$SERVICE_USER' already exists."
fi

echo "Creating directories for user: $SERVICE_USER ($SERVICE_USER:$SERVICE_GROUP)"

# Create main directories
create_acw_directories() {
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /app/autocaliweb
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /calibre-library
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /acw-book-ingest

    # Create config subdirectories (from acw-init service requirements)
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config/processed_books/converted
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config/processed_books/imported
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config/processed_books/failed
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config/processed_books/fixed_originals
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config/log_archive
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config/.acw_conversion_tmp

    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /config/.config/calibre/plugins

    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /app/autocaliweb/metadata_change_logs
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" /app/autocaliweb/metadata_temp
}

# Cleanup like root/etc/s6-overlay/s6-rc.d/acw-init/run
cleanup_lock_files() {
    declare -a lockFiles=("ingest_processor.lock" "convert_library.lock" "cover_enforcer.lock" "kindle_epub_fixer.lock")
    echo "[manual-install] Checking for leftover lock files..."
    counter=0
    for f in "${lockFiles[@]}"; do
        if [ -f "/tmp/$f" ]; then
            echo "[manual-install] Removing leftover $f..."
            rm "/tmp/$f"
            let counter++
        fi
    done
    echo "[manual-install] $counter lock file(s) removed."
}

# Change ownership & permissions as required
change_script_permissions() {
    # Give the group the same permissions as the abc user
    chmod 775 /acw-book-ingest

    # Add the actual user to abc group (-a append)
    sudo usermod -a -G $SERVICE_GROUP $REAL_USER
	# Add the abc user to the actual user group
	sudo usermod -a -G $REAL_GID $SERVICE_USER

    # If Calibre exists copy the plugins otherwise continue
    sudo cp -Ra /home/$REAL_USER/.config/calibre/plugins/. /config/.config/calibre/plugins/ 2>/dev/null || true
    ln -sf /config/.config/calibre/plugins /config/calibre_plugins

    print_status "Directory structure created successfully!"
}

# Checking required dependencies
check_dependencies() {
    print_status "Checking required dependencies..."

    local missing_deps=()

    for cmd in curl git sqlite3 python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        print_error "Please install them before running this script"
        exit 1
    fi
}

# Install system dependencies
install_system_deps() {
    print_status "Installing system dependencies..."

    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        python3-dev python3-pip python3-venv \
        build-essential libldap2-dev libssl-dev libsasl2-dev \
        imagemagick ghostscript \
        libmagic1 libxi6 libxslt1.1 \
        libxtst6 libxrandr2 libxkbfile1 \
        libxcomposite1 libopengl0 libnss3 \
        libxkbcommon0 libegl1 libxdamage1 \
        libgl1 libglx-mesa0 xz-utils \
        sqlite3 xdg-utils inotify-tools \
        netcat-openbsd binutils curl wget
}

# Check directory structure
check_directories() {
    print_status "Checking directory structure..."

    # Check if main directories exist
    if [ ! -d "$INSTALL_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
        print_error "Required directories not found."
        exit 1
    fi

    # Verify ownership
    if [ ! -w "$INSTALL_DIR" ] || [ ! -w "$CONFIG_DIR" ]; then
        print_error "Insufficient permissions for required directories."
        exit 1
    fi

    print_status "Directory structure verified"
}

# Download and setup Autocaliweb [Currently we don't download]
# TODO: Add download/clone step
setup_autocaliweb() {
    print_status "Setting up Autocaliweb..."

    cd "$INSTALL_DIR"

    # Clone or download Autocaliweb (assuming you have the source)
    if [ ! -f "requirements.txt" ]; then
        print_error "Please ensure Autocaliweb source code is in $INSTALL_DIR"
        exit 1
    fi

    # Create virtual environment
    echo "Setting up Autocaliweb Python environment..."
    python3 -m venv venv

    source venv/bin/activate

    # Upgrade pip and install dependencies
    echo "Installing core Python requirements..."
    pip install -U pip wheel
    pip install -r requirements.txt

    read -p "Do you want to install optional dependencies? (y/n): " install_optional
    if [[ "$install_optional" == "y" || "$install_optional" == "Y" ]]; then
        echo "Installing optional Python dependencies..."
        pip install -r optional-requirements.txt
        echo "Optional dependencies setup complete."
    fi

    chown -R "$SERVICE_USER:$SERVICE_GROUP" venv

    print_status "Autocaliweb installed successfully"
}

# Separate function for Calibre installation
install_calibre() {
    print_status "Installing Calibre..."
    sudo mkdir -p /app/calibre
    CALIBRE_RELEASE=$(curl -s https://api.github.com/repos/kovidgoyal/calibre/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    CALIBRE_VERSION=${CALIBRE_RELEASE#v}
    CALIBRE_ARCH=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/')

    curl -o /tmp/calibre.txz -L "https://download.calibre-ebook.com/${CALIBRE_VERSION}/calibre-${CALIBRE_VERSION}-${CALIBRE_ARCH}.txz"
    sudo tar xf /tmp/calibre.txz -C /app/calibre
    sudo /app/calibre/calibre_postinstall
    rm /tmp/calibre.txz
    chown -R "$SERVICE_USER:$SERVICE_GROUP" /app/calibre
    echo "$CALIBRE_RELEASE" >/app/CALIBRE_RELEASE
}

# Separate function for Kepubify installation
install_kepubify() {
    print_status "Installing Kepubify..."
    KEPUBIFY_RELEASE=$(curl -s https://api.github.com/repos/pgaskin/kepubify/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    ARCH=$(uname -m | sed 's/x86_64/64bit/;s/aarch64/arm64/')

    sudo curl -Lo /usr/bin/kepubify "https://github.com/pgaskin/kepubify/releases/download/${KEPUBIFY_RELEASE}/kepubify-linux-${ARCH}"
    sudo chmod +x /usr/bin/kepubify
    echo "$KEPUBIFY_RELEASE" >/app/KEPUBIFY_RELEASE
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

        echo "Using existing Calibre at: $CALIBRE_PATH"
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
        echo "Using existing Kepubify at: $KEPUBIFY_PATH"
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

# Initialize databases with detected binary paths
initialize_databases() {
    print_status "Initializing databases..."

    # Detect binary paths
    KEPUBIFY_PATH=$(which kepubify 2>/dev/null || echo "/usr/bin/kepubify")
    EBOOK_CONVERT_PATH=$(which ebook-convert 2>/dev/null || echo "/usr/bin/ebook-convert")
    CALIBRE_BIN_DIR=$(dirname "$EBOOK_CONVERT_PATH")

    # Copy template app.db if it doesn't exist
    # Currently, some modules expect the app.db to be inside the install directory, while others
    # expect it in config. Until we unify that, we will keep one instance of the file in one
    # place and make a symbolic link at the other location.
    if [ ! -f "$INSTALL_DIR/app.db" ]; then
        if [ -f "$INSTALL_DIR/library/app.db" ]; then
            cp "$INSTALL_DIR/library/app.db" "$INSTALL_DIR/app.db"
            chown -R "$SERVICE_USER:$SERVICE_GROUP" $INSTALL_DIR/app.db
            print_status "Template app.db copyed to $CONFIG_DIR"
        else
            print_warning "Template app.db not found, will be created on first run"
        fi
    fi
    if [ ! -f "$CONFIG_DIR/app.db" ]; then
        if [ -f "$INSTALL_DIR/app.db" ]; then
            # Create symbolic link for app.db
            ln -sf /app/autocaliweb/app.db /config/app.db
            chown -R "$SERVICE_USER:$SERVICE_GROUP" $CONFIG_DIR/app.db
            print_status "Template app.db linked to $CONFIG_DIR"
        else
            print_warning "Template app.db not found, will be created on first run"
        fi
    fi

    # Set correct binary paths in database
    if [ -f "$CONFIG_DIR/app.db" ]; then
        sqlite3 "$CONFIG_DIR/app.db" <<EOS
UPDATE settings SET
    config_kepubifypath='$KEPUBIFY_PATH',
    config_converterpath='$EBOOK_CONVERT_PATH',
    config_binariesdir='$CALIBRE_BIN_DIR'
WHERE 1=1;
EOS
        print_status "Binary paths configured in database: Kepubify=$KEPUBIFY_PATH, ebook-convert=$EBOOK_CONVERT_PATH"
    fi
}

# Create systemd service
create_systemd_service() {
    print_status "Creating systemd service..."

    sudo tee /etc/systemd/system/autocaliweb.service >/dev/null <<EOF
[Unit]
Description=Autocaliweb
After=network.target

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

    sudo systemctl daemon-reload
    sudo systemctl enable autocaliweb

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

    # Create metadata directories
    #    mkdir -p "$INSTALL_DIR"/{metadata_change_logs,metadata_temp}
    # Create Autocaliweb version file
    if git rev-parse --git-dir >/dev/null 2>&1; then
        echo "manual-v$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo '1.0.0')" >/app/ACW_RELEASE
    else
        echo "manual-v1.0.0" >/app/ACW_RELEASE
    fi

    print_status "Configuration files updated"
}

# Set permissions
set_permissions() {
    print_status "Setting permissions..."

    # Set ownership for all directories
    sudo chown -R $SERVICE_USER:$SERVICE_GROUP "$INSTALL_DIR" "$CONFIG_DIR" "$CALIBRE_LIB_DIR" "$INGEST_DIR" /app

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
    echo "Creating systemd service for acw-ingest-service..."

    # Create wrapper script
    sudo tee ${INSTALL_DIR}/scripts/ingest_watcher.sh >/dev/null <<EOF
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
    echo "Creating systemd service for acw-ingest-service..."
    cat <<EOF | sudo tee /etc/systemd/system/acw-ingest-service.service
[Unit]
Description=Autocaliweb Ingest Processor Service
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment=CALIBRE_DBPATH=/config
Environment=HOME=/config
# We can't extract WATCH_FOLDER from dirs.json and pass it to inotifywait
# as the Docker acw-ingest-service works. To avoid ‘Unit does not exist’ error
# we need a Wrapper Script (ingest_watcher.sh)
ExecStart=/bin/bash ${INSTALL_DIR}/scripts/ingest_watcher.sh
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable acw-ingest-service
    print_status "Autocaliweb ingest service created and enabled"
}

create_auto_zipper_service() {
    echo "Creating systemd service for acw-auto-zipper..."

    # Create wrapper script
    sudo tee ${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh >/dev/null <<EOF
#!/bin/bash

# Source virtual environment
source ${INSTALL_DIR}/venv/bin/activate

WAKEUP="23:59"

while true; do
    SECS=\$(expr \`date -d "\$WAKEUP" +%s\` - \`date -d "now" +%s\`)
    if [[ \$SECS -lt 0 ]]; then
    SECS=\$(expr \`date -d "tomorrow \$WAKEUP" +%s\` - \`date -d "now" +%s\`)
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

    sudo chmod +x ${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh
    sudo chown ${SERVICE_USER}:${SERVICE_GROUP} ${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh

    # Create systemd service
    cat <<EOF | sudo tee /etc/systemd/system/acw-auto-zipper.service
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

    sudo systemctl daemon-reload
    sudo systemctl enable acw-auto-zipper
    print_status "Auto-zipper service created and enabled"
}


# --- metadata-change-detector service
# This would require cover_enforcer.py to have a continuous watch mode
create_metadata_change_detector(){
echo "Creating systemd service for metadata-change-detector..."
    # Create wrapper script
    sudo tee ${INSTALL_DIR}/scripts/metadata_change_detector_wrapper.sh >/dev/null <<EOF
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

 cat <<EOF | sudo tee /etc/systemd/system/metadata-change-detector.service
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

    sudo systemctl daemon-reload
    sudo systemctl enable metadata-change-detector
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

    echo "[manual-install] Setting ownership of directories to $SERVICE_USER:$SERVICE_GROUP..."

    for d in "${requiredDirs[@]}"; do
        if [ -d "$d" ]; then
            chown -R "$SERVICE_USER:$SERVICE_GROUP" "$d"
            chmod -R 775 "$d"
            echo "[manual-install] Set permissions for '$d'"
        fi
    done
}

start_acw_services() {
sudo systemctl start autocaliweb
if systemctl is-active --quiet autocaliweb; then
    print_status "autocaliweb  service started"
fi
if [ -f "${INSTALL_DIR}/scripts/ingest_watcher.sh" ]; then
    sudo systemctl start acw-ingest-service
    if systemctl is-active --quiet acw-ingest-service; then
        print_status "acw-ingest-service service started"
    fi
fi
sudo systemctl start acw-auto-zipper
if [ -f "${INSTALL_DIR}/scripts/auto_zipper_wrapper.sh" ]; then
    sudo systemctl start acw-auto-zipper
    if systemctl is-active --quiet acw-auto-zipper; then
        print_status "acw-auto-zipper service started"
    fi
fi
if [ -f "${INSTALL_DIR}/scripts/cover_enforcer.py" ]; then
    sudo systemctl start metadata-change-detector
    if systemctl is-active --quiet metadata-change-detector; then
        print_status "metadata-change-detector service started"
    fi
fi
}
# Main installation process
main() {
    print_status "Starting Autocaliweb manual installation..."
    create_acw_directories
    change_script_permissions
    check_dependencies
    install_system_deps
    check_directories
    setup_autocaliweb
    install_external_tools
    setup_configuration
    initialize_databases
    set_permissions
    create_startup_script
    create_systemd_service
    create_acw_ingest_service
    create_auto_zipper_service
    create_metadata_change_detector
    run_auto_library
    start_acw_services
    set_acw_permissions

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
