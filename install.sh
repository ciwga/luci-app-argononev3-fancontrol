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

echo "========================================================"
echo "   Argon ONE V3 Fan Control Installer                   "
echo "   OpenWrt / Raspberry Pi 5                             "
echo "========================================================"

if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root. Please log in as root and try again."
    exit 1
fi

# ==============================================================================
# PHASE 0: PRE-INSTALL CLEANUP (Clean-Slate)
# ==============================================================================
log_step "Phase 0: Pre-Install Cleanup"

if [ -f "/etc/init.d/argon_daemon" ]; then
    log_info "Stopping existing installation..."
    /etc/init.d/argon_daemon stop >/dev/null 2>&1 || true
    /etc/init.d/argon_daemon disable >/dev/null 2>&1 || true
fi

killall -9 argon_fan_control.sh 2>/dev/null || true
killall -9 argon_update.sh 2>/dev/null || true

rm -f /var/run/argon_fan.status /var/run/argon_fan.status.tmp /var/run/argon_fan.lock/pid 2>/dev/null || true
rmdir /var/run/argon_fan.lock 2>/dev/null || true
rm -f /etc/argon_version /tmp/argon_update.ipk /tmp/argononev3_latest.ipk /tmp/argon_update_install.log 2>/dev/null || true
rm -f /etc/config/argononev3-opkg /etc/config/argononev3.bak 2>/dev/null || true
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

# Fan off during upgrade window
for dev in /dev/i2c-*; do
    [ -e "$dev" ] || continue
    bus="${dev##*-}"
    if i2cdetect -y -r "$bus" 2>/dev/null | grep -q "1a"; then
        i2cset -y -f "$bus" 0x1a 0x80 0x00 2>/dev/null || true
        log_info "Fan MCU set to OFF on bus $bus."
        break
    fi
done

log_info "Cleanup complete."

# ==============================================================================
# STEP 1: DEPENDENCIES
# ==============================================================================
log_step "Step 1: Installing Dependencies"
opkg update >/dev/null 2>&1

if opkg install i2c-tools; then
    log_info "'i2c-tools' ready."
else
    log_err "Failed to install 'i2c-tools'."
    exit 1
fi

# ==============================================================================
# STEP 2: DOWNLOAD & INSTALL PACKAGE
# ==============================================================================
log_step "Step 2: Downloading Latest Package"

API_URL="https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/latest"
RELEASE_JSON=$(wget -qO- "$API_URL" 2>/dev/null) || { log_err "GitHub API unreachable."; exit 1; }

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | sed -n 's/.*"browser_download_url": *"\([^"]*\.ipk\)".*/\1/p' | head -n 1)
REMOTE_TAG=$(echo "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    log_err "No .ipk found in latest release."
    exit 1
fi

log_info "Latest: ${REMOTE_TAG:-unknown}"
IPK_FILE="/tmp/argononev3_latest.ipk"

if wget --no-check-certificate -q -O "$IPK_FILE" "$DOWNLOAD_URL"; then
    log_info "Download complete."
    if opkg install --force-maintainer --force-overwrite "$IPK_FILE"; then
        log_info "Package installed."
    else
        log_err "Installation failed."; rm -f "$IPK_FILE"; exit 1
    fi
    rm -f "$IPK_FILE"
else
    log_err "Download failed."; exit 1
fi

# ==============================================================================
# STEP 3: I2C HARDWARE CONFIG
# ==============================================================================
log_step "Step 3: Hardware Configuration (I2C)"
CONFIG_FILE="/boot/config.txt"
I2C_PARAM="dtparam=i2c_arm=on"
REBOOT_REQUIRED=0

if [ -f "$CONFIG_FILE" ]; then
    if grep -q "^$I2C_PARAM" "$CONFIG_FILE"; then
        log_info "I2C already enabled."
    else
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
        echo "" >> "$CONFIG_FILE"
        echo "# Added by Argon ONE Installer" >> "$CONFIG_FILE"
        echo "$I2C_PARAM" >> "$CONFIG_FILE"
        log_info "I2C enabled. Reboot required."
        REBOOT_REQUIRED=1
    fi
else
    log_warn "$CONFIG_FILE not found. Enable I2C manually if needed."
fi

# ==============================================================================
# STEP 4: SERVICE INIT
# ==============================================================================
log_step "Step 4: Service Initialization"

if [ ! -f "/etc/init.d/argon_daemon" ]; then
    log_err "/etc/init.d/argon_daemon missing. Install may be broken."
    exit 1
fi

if [ -f "/etc/argon_version" ]; then
    log_info "Installed version: $(cat /etc/argon_version)"
fi

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/argon_daemon enable

if [ "$REBOOT_REQUIRED" -eq 0 ]; then
    /etc/init.d/argon_daemon start
    log_info "Daemon started."
else
    log_warn "Daemon enabled but requires reboot for I2C bus."
fi

echo "========================================================"
echo -e "${GREEN}   INSTALLATION COMPLETE!${NC}"
echo "========================================================"

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    echo -e "${YELLOW}IMPORTANT: Reboot required for I2C. Run: ${CYAN}reboot${NC}"
else
    echo -e "Web UI: ${CYAN}LuCI -> Services -> Argon ONE V3 Fan${NC}"
fi