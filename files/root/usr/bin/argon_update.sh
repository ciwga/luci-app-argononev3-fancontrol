#!/bin/sh

# ==============================================================================
# FILE: /usr/bin/argon_update.sh
# DESCRIPTION: Secure Over-The-Air (OTA) Updater for Argon ONE V3 Fan Control
# AUTHOR: ciwga
#
# This script is strictly confined and takes no arguments to prevent 
# Command Injection vulnerabilities when triggered via the LuCI Web RPC.
# ==============================================================================

set -u
set -e
export LC_ALL=C

log_msg() { logger -t argon_updater -p daemon.notice "[INFO] $1"; }
log_err() { logger -t argon_updater -p daemon.err "[ERROR] $1"; }

log_msg "Update process initiated by User via Web UI."

readonly REPO_USER="ciwga"
readonly REPO_NAME="luci-app-argononev3-fancontrol"
readonly API_URL="https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/latest"

# 1. Fetch the latest release URL safely from GitHub API
DOWNLOAD_URL=$(wget -qO- "$API_URL" | sed -n 's/.*"browser_download_url": *"\([^"]*\.ipk\)".*/\1/p' | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    log_err "Failed to fetch the latest .ipk download URL from GitHub API."
    exit 1
fi

readonly IPK_FILE="/tmp/argon_update.ipk"
log_msg "Downloading latest release from: $DOWNLOAD_URL"

# 2. Download and overwrite install
if wget --no-check-certificate -q -O "$IPK_FILE" "$DOWNLOAD_URL"; then
    log_msg "Download successful. Installing via opkg..."
    
    # Run opkg with force options to smoothly upgrade existing configurations
    # Added --force-reinstall to guarantee files are overwritten even if version matches
    if opkg install --force-maintainer --force-overwrite --force-reinstall "$IPK_FILE" >/tmp/argon_update_install.log 2>&1; then
        log_msg "Update completed successfully. Cleaning up..."
        rm -f "$IPK_FILE"
        
        # Give OpenWrt's procd a moment to settle before restarting the daemon
        sleep 2
        /etc/init.d/argon_daemon restart || true
        log_msg "Daemon restarted. Update sequence finished."
        exit 0
    else
        log_err "opkg installation failed. Check /tmp/argon_update_install.log for details."
        rm -f "$IPK_FILE"
        exit 1
    fi
else
    log_err "Failed to download the .ipk file from GitHub."
    exit 1
fi