#!/bin/bash
# prep_autocaliweb.sh - Run this as root first
#
# Copyright (C) 2025 Autocaliweb
# First creator UsamaFoad <usamafoad@gmail.com>
echo "=== Autocaliweb Directory Preparation Script ==="
  
# Check if running as root
if [[ $EUID -ne 0 ]]; then  
   echo "This script must be run as root (use sudo)"
   exit 1
fi  
  
# Get the actual user who called sudo
REAL_USER=${SUDO_USER:-$USER}
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

echo "Creating directories for user: $REAL_USER ($REAL_UID:$REAL_GID)"
  
# Create main directories
mkdir -p /app/autocaliweb
mkdir -p /config
mkdir -p /calibre-library
mkdir -p /acw-book-ingest

# Create config subdirectories (from acw-init service requirements)
mkdir -p /config/processed_books/{converted,imported,failed,fixed_originals}
mkdir -p /config/log_archive
mkdir -p /config/.acw_conversion_tmp
mkdir -p /config/.config/calibre/plugins
  
# Set ownership to the real user
chown -R "$REAL_UID:$REAL_GID" /app/autocaliweb
chown -R "$REAL_UID:$REAL_GID" /config
chown -R "$REAL_UID:$REAL_GID" /calibre-library
chown -R "$REAL_UID:$REAL_GID" /acw-book-ingest

# Create symbolic link for calibre plugins
ln -sf /config/.config/calibre/plugins /config/calibre_plugins
  
echo "Directory structure created successfully!"
echo "Now run: ./install_autocaliweb.sh (as regular user)"
