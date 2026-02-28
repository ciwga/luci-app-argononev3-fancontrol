#!/bin/sh

# ==============================================================================
# FILE: /usr/bin/argon_fan_test.sh
# DESCRIPTION: Confined fan test trigger for LuCI RPC
# AUTHOR: ciwga
#
# EXIT CODES:
#   0 = Signal sent successfully
#   1 = Daemon not running or PID file missing
# ==============================================================================

set -u
export LC_ALL=C

readonly PID_FILE="/var/run/argon_fan.lock/pid"

# Verify PID file exists and is readable
if [ ! -r "$PID_FILE" ]; then
    logger -t argon_test -p daemon.notice "[INFO] Fan test failed: PID file not found."
    exit 1
fi

# Read PID safely
DAEMON_PID=""
read -r DAEMON_PID < "$PID_FILE" 2>/dev/null || true

# Validate PID is a number (prevent injection via crafted PID file)
case "$DAEMON_PID" in
    ''|*[!0-9]*)
        logger -t argon_test -p daemon.err "[ERROR] Invalid PID in lock file."
        exit 1
        ;;
esac

# Verify process is actually alive before sending signal
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    logger -t argon_test -p daemon.notice "[INFO] Fan test failed: daemon PID $DAEMON_PID not running."
    exit 1
fi

# Send SIGUSR1 to trigger fan test
if kill -USR1 "$DAEMON_PID" 2>/dev/null; then
    logger -t argon_test -p daemon.notice "[INFO] Fan test signal sent to PID $DAEMON_PID."
    exit 0
else
    logger -t argon_test -p daemon.err "[ERROR] Failed to send signal to PID $DAEMON_PID."
    exit 1
fi