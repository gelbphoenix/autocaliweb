#!/bin/bash
# uninstall_autocaliweb.sh - Autocaliweb Manual Installation Uninstaller
#
# Copyright (C) 2025 Autocaliweb

set -e

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

echo "=== Autocaliweb Manual Installation Uninstaller ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
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
    echo "  sudo rm -rf /app/autocaliweb /config /calibre-library /acw-book-ingest"
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
