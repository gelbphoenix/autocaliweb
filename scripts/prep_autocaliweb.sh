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

# Create main directories & Set ownership to the real user
install -d -o "$REAL_UID" -g "$REAL_GID" /app/autocaliweb
install -d -o "$REAL_UID" -g "$REAL_GID" /config
install -d -o "$REAL_UID" -g "$REAL_GID" /calibre-library
install -d -o "$REAL_UID" -g "$REAL_GID" /acw-book-ingest

# Create config subdirectories (from acw-init service requirements)
install -d -o "$REAL_UID" -g "$REAL_GID" /config/processed_books/converted
install -d -o "$REAL_UID" -g "$REAL_GID" /config/processed_books/imported
install -d -o "$REAL_UID" -g "$REAL_GID" /config/processed_books/failed
install -d -o "$REAL_UID" -g "$REAL_GID" /config/processed_books/fixed_originals
install -d -o "$REAL_UID" -g "$REAL_GID" /config/log_archive
install -d -o "$REAL_UID" -g "$REAL_GID" /config/.acw_conversion_tmp

install -d -o "$REAL_UID" -g "$REAL_GID" /config/.config/calibre/plugins

install -d -o "$REAL_UID" -g "$REAL_GID" /app/autocaliweb/metadata_change_logs
install -d -o "$REAL_UID" -g "$REAL_GID" /app/autocaliweb/metadata_temp

# Create symbolic link for calibre plugins
ln -sf /config/.config/calibre/plugins /config/calibre_plugins

echo "Directory structure created successfully!"
echo "Now run: ./install_autocaliweb.sh (as regular user)"