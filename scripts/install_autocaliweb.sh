#!/bin/bash
# install_autocaliweb.sh - Run as regular user
#
# Copyright (C) 2025 Autocaliweb
# First creator UsamaFoad <usamafoad@gmail.com>
set -e

echo "=== Autocaliweb Manual Installation Script ==="

# Configuration
INSTALL_DIR="/app/autocaliweb"
CONFIG_DIR="/config"
CALIBRE_LIB_DIR="/calibre-library"
INGEST_DIR="/acw-book-ingest"

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

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root for security reasons"
   exit 1
fi

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
        print_error "Required directories not found. Please run prep_autocaliweb.sh as root first."
        print_error "Run: sudo ./prep_autocaliweb.sh"
        exit 1
    fi
    
    # Verify ownership
    if [ ! -w "$INSTALL_DIR" ] || [ ! -w "$CONFIG_DIR" ]; then
        print_error "Insufficient permissions for required directories."
        print_error "Please ensure prep_autocaliweb.sh was run correctly."
        exit 1
    fi
    
    print_status "Directory structure verified"
}

# Download and setup Autocaliweb
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
    fi  
  
    echo "Optional dependencies setup complete."  

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
    echo "$CALIBRE_RELEASE" > /app/CALIBRE_RELEASE
}

# Separate function for Kepubify installation
install_kepubify() {
    print_status "Installing Kepubify..."
    KEPUBIFY_RELEASE=$(curl -s https://api.github.com/repos/pgaskin/kepubify/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    ARCH=$(uname -m | sed 's/x86_64/64bit/;s/aarch64/arm64/')
    
    sudo curl -Lo /usr/bin/kepubify "https://github.com/pgaskin/kepubify/releases/download/${KEPUBIFY_RELEASE}/kepubify-linux-${ARCH}"
    sudo chmod +x /usr/bin/kepubify
    echo "$KEPUBIFY_RELEASE" > /app/KEPUBIFY_RELEASE
}

# Install external tools (with detection)
install_external_tools() {
    print_status "Checking for external tools..."
    
    # Check for existing Calibre installation
    if command -v calibre >/dev/null 2>&1 || command -v ebook-convert >/dev/null 2>&1; then
        print_status "Calibre already installed, skipping installation"
        CALIBRE_PATH=$(dirname $(which ebook-convert 2>/dev/null || which calibre))
        
        # Create Calibre version file
    if command -v calibre >/dev/null 2>&1; then
        if calibre --version | head -1 | cut -d' ' -f3 | sed 's/)//' > /app/CALIBRE_RELEASE 2>/dev/null; then
            print_status "Calibre version file created successfully"  
        else
            print_warning "Could not determine Calibre version, using 'Unknown'"  
            echo "Unknown" > /app/CALIBRE_RELEASE  
        fi  
    else
        echo "Unknown" > /app/CALIBRE_RELEASE  
    fi

        echo "Using existing Calibre at: $CALIBRE_PATH"
    else
        read -p "Calibre not found. Install Calibre? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_calibre
        else
            print_warning "Skipping Calibre installation. You'll need to install it manually."
        echo "Unknown" > /app/CALIBRE_RELEASE
        fi
    fi
    
    # Check for existing Kepubify installation
    if command -v kepubify >/dev/null 2>&1; then
        print_status "Kepubify already installed, skipping installation"
        KEPUBIFY_PATH=$(which kepubify)
    kepubify --version | head -1 | cut -d' ' -f2 > /app/KEPUBIFY_RELEASE
        echo "Using existing Kepubify at: $KEPUBIFY_PATH"
    else
        read -p "Kepubify not found. Install Kepubify? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_kepubify
        else
            print_warning "Skipping Kepubify installation. You'll need to install it manually."
        echo "Unknown" > /app/KEPUBIFY_RELEASE
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
    if [ ! -f "$CONFIG_DIR/app.db" ]; then
        if [ -f "$INSTALL_DIR/library/app.db" ]; then
            cp "$INSTALL_DIR/library/app.db" "$CONFIG_DIR/app.db"
            print_status "Template app.db copied to $CONFIG_DIR"
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
    
    sudo tee /etc/systemd/system/autocaliweb.service > /dev/null <<EOF
[Unit]
Description=Autocaliweb
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$INSTALL_DIR
Environment=PATH=$INSTALL_DIR/venv/bin:/usr/bin:/bin
Environment=PYTHONPATH=$INSTALL_DIR/scripts:$INSTALL_DIR
Environment=CALIBRE_DBPATH=$CONFIG_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/cps.py
Restart=always
RestartSec=10

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
    cat > "$INSTALL_DIR/dirs.json" <<EOF
{
  "ingest_folder": "$INGEST_DIR",
  "calibre_library_dir": "$CALIBRE_LIB_DIR",
  "tmp_conversion_dir": "$CONFIG_DIR/.acw_conversion_tmp"
}
EOF
    
    # Create metadata directories
    mkdir -p "$INSTALL_DIR"/{metadata_change_logs,metadata_temp}
    # Create Autocaliweb version file
    if git rev-parse --git-dir > /dev/null 2>&1; then  
        echo "manual-v$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo '1.0.0')" > /app/ACW_RELEASE  
    else  
        echo "manual-v1.0.0" > /app/ACW_RELEASE  
    fi
    
    print_status "Configuration files updated"
}

# Set permissions
set_permissions() {
    print_status "Setting permissions..."
    
    # Set ownership for all directories
    sudo chown -R $USER:$USER "$INSTALL_DIR" "$CONFIG_DIR" "$CALIBRE_LIB_DIR" "$INGEST_DIR" /app
    
    # Set executable permissions for scripts
    find "$INSTALL_DIR/scripts" -name "*.py" -exec chmod +x {} \;
    chmod +x "$INSTALL_DIR/cps.py"
    
    print_status "Permissions set successfully"
}

# Create startup script
create_startup_script() {
    print_status "Creating startup script..."
    
    cat > "$INSTALL_DIR/start_autocaliweb.sh" <<EOF
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

# Main installation process
main() {
    print_status "Starting Autocaliweb manual installation..."
    
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
    
    print_status "Installation completed successfully!"
    echo
    echo "=== Next Steps ==="
    echo "1. Start the service: sudo systemctl start autocaliweb"
    echo "2. Check status: sudo systemctl status autocaliweb"
    echo "3. View logs: sudo journalctl -u autocaliweb -f"
    echo "4. Access web interface: http://localhost:8083"
    echo "5. Default login: admin/admin123"
    echo
    echo "=== Manual Start (Alternative) ==="
    echo "Run: $INSTALL_DIR/start_autocaliweb.sh"
    echo
    echo "=== Configuration ==="
    echo "- Main config: $CONFIG_DIR/app.db"
    echo "- Directory config: $INSTALL_DIR/dirs.json"
    echo "- Calibre library: $CALIBRE_LIB_DIR"
    echo "- Book ingest: $INGEST_DIR"
    echo
    echo "=== Important Notes ==="
    echo "- If you encounter hardcoded path errors, you may need to:"
    echo "  1. Update scripts/acw_db.py schema_path to use $INSTALL_DIR"
    echo "  2. Create missing directories manually"
    echo "  3. Check file permissions if database errors occur"
    echo
    echo "=== Prerequisites ==="  
    echo "- Ensure prep_autocaliweb.sh was run as root first"  
    echo "- Autocaliweb source code should be in $INSTALL_DIR"
}

# Run main function
main "$@"