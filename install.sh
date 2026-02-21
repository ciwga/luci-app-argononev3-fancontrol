#!/bin/sh

# ==============================================================================
# Argon ONE V3 Fan Control Automated Installer for OpenWrt (Raspberry Pi 5)
# Author: ciwga
# Description: Automatically installs i2c-tools, enables I2C in boot config, 
#              fetches the latest .ipk release from GitHub, and sets up the daemon.
# ==============================================================================

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
REPO_USER="ciwga"
REPO_NAME="luci-app-argononev3-fancontrol"

# Colors for terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}>>> $1${NC}"; }

# ------------------------------------------------------------------------------
# INSTALLATION PROCESS
# ------------------------------------------------------------------------------

echo "========================================================"
echo "   Argon ONE V3 Fan Control Installer (OpenWrt/RPi5)    "
echo "========================================================"

# 1. Check Root Privileges
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root. Please log in as root and try again."
    exit 1
fi

# 2. Update and Install Dependencies
log_step "Step 1: Installing System Dependencies"
log_info "Updating opkg package lists..."
opkg update >/dev/null 2>&1

if opkg install i2c-tools; then
    log_info "Dependency 'i2c-tools' installed successfully."
else
    log_err "Failed to install 'i2c-tools'. Please check your internet connection."
    exit 1
fi

# 3. Fetch and Install the Latest IPK from GitHub Releases
log_step "Step 2: Downloading the Latest Package"
log_info "Querying GitHub API for the latest release..."

API_URL="https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/latest"

DOWNLOAD_URL=$(wget -qO- "$API_URL" | sed -n 's/.*"browser_download_url": *"\([^"]*\.ipk\)".*/\1/p' | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    log_err "Failed to find the latest .ipk release URL."
    log_err "Check if GitHub API is rate-limited or if the release contains the .ipk asset."
    exit 1
fi

log_info "Latest release found: $DOWNLOAD_URL"
IPK_FILE="/tmp/argononev3_latest.ipk"

if wget --no-check-certificate -q -O "$IPK_FILE" "$DOWNLOAD_URL"; then
    log_info "Download complete. Installing the package via opkg..."
    
    # --force-maintainer: Overwrites existing config files with the new ones from the package.
    # --force-overwrite: Forces overwriting of files owned by other packages if necessary.
    if opkg install --force-maintainer --force-overwrite "$IPK_FILE"; then
        log_info "Package installed successfully (Configuration updated)."
    else
        log_err "Package installation failed."
        rm -f "$IPK_FILE"
        exit 1
    fi
    rm -f "$IPK_FILE"
else
    log_err "Failed to download the .ipk file."
    exit 1
fi

# 4. Configure /boot/config.txt for I2C
log_step "Step 3: Hardware Configuration (I2C)"
CONFIG_FILE="/boot/config.txt"
I2C_PARAM="dtparam=i2c_arm=on"
REBOOT_REQUIRED=0

if [ -f "$CONFIG_FILE" ]; then
    if grep -q "^$I2C_PARAM" "$CONFIG_FILE"; then
        log_info "I2C bus is already enabled in $CONFIG_FILE."
    else
        log_info "Enabling I2C support in boot configuration..."
        
        # Create a secure backup before modification
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
        log_info "Backup created at $CONFIG_FILE.bak"

        # Safely append the configuration
        echo "" >> "$CONFIG_FILE"
        echo "# Added automatically by Argon ONE Installer" >> "$CONFIG_FILE"
        echo "$I2C_PARAM" >> "$CONFIG_FILE"
        log_info "I2C parameter successfully injected into config.txt."
        
        REBOOT_REQUIRED=1
    fi
else
    log_warn "$CONFIG_FILE not found! You may need to enable the I2C bus manually depending on your firmware."
fi

# 5. Clean up Ghost Processes and Start Service
log_step "Step 4: Service Initialization"
log_info "Cleaning up legacy ghost processes and lock files..."

# Graceful check for the init script before execution
if [ -f "/etc/init.d/argon_daemon" ]; then
    /etc/init.d/argon_daemon stop >/dev/null 2>&1 || true
    /etc/init.d/argon_daemon enable
else
    log_err "Installation error: /etc/init.d/argon_daemon not found. The .ipk may not have installed correctly."
    exit 1
fi

killall -9 argon_fan_control.sh 2>/dev/null || true
rm -f /var/run/argon_fan.status /var/run/argon_fan.lock/* 2>/dev/null || true

log_info "Restarting RPC daemon..."
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

if [ "$REBOOT_REQUIRED" -eq 0 ]; then
    /etc/init.d/argon_daemon start
    log_info "Daemon started successfully."
else
    log_warn "Daemon enabled, but requires a system reboot to initialize the I2C bus."
fi

echo "========================================================"
echo -e "${GREEN}   INSTALLATION COMPLETE!   ${NC}"
echo "========================================================"

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    echo -e "${YELLOW}IMPORTANT: A system reboot is strictly required to activate the I2C hardware bus.${NC}"
    echo -e "Please run the following command to reboot now: ${CYAN}reboot${NC}"
fi