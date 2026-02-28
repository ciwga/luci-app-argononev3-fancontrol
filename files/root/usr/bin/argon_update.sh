#!/bin/sh

# ==============================================================================
# FILE: /usr/bin/argon_update.sh
# DESCRIPTION: Secure OTA Updater for Argon ONE V3 Fan Control
# AUTHOR: ciwga
#
# Exit codes: 0 = updated, 1 = error, 2 = already up-to-date
# ==============================================================================

set -u
set -e
export LC_ALL=C

log_msg() { logger -t argon_updater -p daemon.notice "[INFO] $1"; }
log_err() { logger -t argon_updater -p daemon.err "[ERROR] $1"; }

log_msg "Update initiated via Web UI."

readonly REPO_USER="ciwga"
readonly REPO_NAME="luci-app-argononev3-fancontrol"
readonly API_URL="https://api.github.com/repos/$REPO_USER/$REPO_NAME/releases/latest"
readonly VERSION_FILE="/etc/argon_version"

# Step 1: Read installed version from /etc/argon_version
INSTALLED_VERSION="unknown"
if [ -r "$VERSION_FILE" ]; then
    read -r RAW_VER < "$VERSION_FILE" 2>/dev/null || RAW_VER=""
    INSTALLED_VERSION=$(echo "$RAW_VER" | sed 's/[^a-zA-Z0-9._-]//g')
fi
[ -z "$INSTALLED_VERSION" ] && INSTALLED_VERSION="unknown"
log_msg "Installed: $INSTALLED_VERSION"

# Step 2: Fetch latest release from GitHub
RELEASE_JSON=$(wget -qO- "$API_URL" 2>/dev/null) || {
    log_err "GitHub API unreachable."
    exit 1
}

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | sed -n 's/.*"browser_download_url": *"\([^"]*\.ipk\)".*/\1/p' | head -n 1)
REMOTE_TAG=$(echo "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    log_err "No .ipk found in latest release."
    exit 1
fi

REMOTE_TAG=$(echo "$REMOTE_TAG" | sed 's/[^a-zA-Z0-9._-]//g')
[ -z "$REMOTE_TAG" ] && REMOTE_TAG="unknown"
log_msg "Remote: $REMOTE_TAG"

# Step 3: Version comparison
if [ "$INSTALLED_VERSION" != "unknown" ] && [ "$REMOTE_TAG" != "unknown" ]; then
    NORM_REMOTE=$(echo "$REMOTE_TAG" | sed 's/^[vV]//')
    NORM_LOCAL=$(echo "$INSTALLED_VERSION" | sed 's/^[vV]//')
    
    case "$NORM_LOCAL" in
        "${NORM_REMOTE}"*)
            log_msg "Up-to-date ($INSTALLED_VERSION = $REMOTE_TAG)."
            exit 2
            ;;
    esac
    log_msg "Update: $INSTALLED_VERSION -> $REMOTE_TAG"
fi

# Step 4: Download and install
readonly IPK_FILE="/tmp/argon_update.ipk"
log_msg "Downloading: $DOWNLOAD_URL"

if wget --no-check-certificate -q -O "$IPK_FILE" "$DOWNLOAD_URL"; then
    log_msg "Installing..."
    if opkg install --force-maintainer --force-overwrite --force-reinstall "$IPK_FILE" >/tmp/argon_update_install.log 2>&1; then
        log_msg "Update complete."
        rm -f "$IPK_FILE"
        sleep 2
        /etc/init.d/argon_daemon restart || true
        log_msg "Daemon restarted."
        exit 0
    else
        log_err "opkg failed. See /tmp/argon_update_install.log"
        rm -f "$IPK_FILE"
        exit 1
    fi
else
    log_err "Download failed."
    rm -f "$IPK_FILE"
    exit 1
fi