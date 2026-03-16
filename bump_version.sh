#!/bin/sh
# ==============================================================================
# FILE: bump_version.sh
# DESCRIPTION: Single source of truth version bumper for luci-app-argononev3
#
# USAGE:
#   ./bump_version.sh 3.1.1
#
# WHAT IT UPDATES:
#   Makefile              → PKG_VERSION, PKG_RELEASE, header comment
#   argon_fan_control.sh  → header comment
#   argon_fan_test.sh     → header comment
#   argon_update.sh       → header comment
#   argon_daemon          → header comment
#   install.sh            → header comment + banner line
#
# RUNTIME VERSION SOURCE:
#   /etc/argon_version    → written by Makefile postinst from PKG_VERSION.
#                           All shell scripts read from here at runtime,
#                           so they need no hardcoded version at all.
# ==============================================================================

set -e

NEW_VERSION="$1"

if [ -z "$NEW_VERSION" ]; then
    echo "Usage: $0 <version>   e.g.  $0 3.1.1"
    exit 1
fi

# Validate: only digits and dots allowed
case "$NEW_VERSION" in
    *[!0-9.]*) echo "Error: version must be numeric (e.g. 3.1.1)"; exit 1 ;;
esac

# Derive PKG_RELEASE — reset to 1 on every version bump
PKG_RELEASE=1

echo "Bumping to v${NEW_VERSION}-${PKG_RELEASE} ..."

# ------------------------------------------------------------------------------
# Helper: replace the first matching line in a file (POSIX sed -i portably)
# ------------------------------------------------------------------------------
replace() {
    local file="$1" pattern="$2" replacement="$3"
    sed -i "s|${pattern}|${replacement}|" "$file"
}

# ------------------------------------------------------------------------------
# Makefile — PKG_VERSION, PKG_RELEASE, header comment
# ------------------------------------------------------------------------------
OLD_PKG_VERSION=$(grep '^PKG_VERSION:=' Makefile | sed 's/PKG_VERSION:=//')
replace Makefile \
    "^PKG_VERSION:=.*" \
    "PKG_VERSION:=${NEW_VERSION}"
replace Makefile \
    "^PKG_RELEASE:=.*" \
    "PKG_RELEASE:=${PKG_RELEASE}"
replace Makefile \
    "^# VERSION:.*" \
    "# VERSION: ${NEW_VERSION}"

# ------------------------------------------------------------------------------
# Shell scripts — header comment only (runtime version comes from /etc/argon_version)
# ------------------------------------------------------------------------------
for f in \
    files/root/usr/bin/argon_fan_control.sh \
    files/root/usr/bin/argon_fan_test.sh \
    files/root/usr/bin/argon_update.sh \
    files/root/etc/init.d/argon_daemon
do
    replace "$f" \
        "^# VERSION:.*" \
        "# VERSION: ${NEW_VERSION}"
done

# ------------------------------------------------------------------------------
# install.sh — header comment + banner echo line
# ------------------------------------------------------------------------------
replace install.sh \
    "^# Version:.*" \
    "# Version: ${NEW_VERSION}"
replace install.sh \
    "Argon ONE V3 Fan Control Installer v[0-9][0-9.]*" \
    "Argon ONE V3 Fan Control Installer v${NEW_VERSION}"

echo ""
echo "Done. Changes made:"
grep -rn "VERSION\|Version\|PKG_VERSION\|PKG_RELEASE\|Installer v" \
    Makefile \
    files/root/usr/bin/argon_fan_control.sh \
    files/root/usr/bin/argon_fan_test.sh \
    files/root/usr/bin/argon_update.sh \
    files/root/etc/init.d/argon_daemon \
    install.sh \
    | grep -v "INSTALLED_VERSION\|REMOTE\|argon_version\|VERSION_FILE\|log_msg\|log_err\|CHANGELOG"
echo ""