#!/bin/sh

# ==============================================================================
# FILE: /usr/bin/argon_fan_control.sh
# DESCRIPTION: Argon ONE V3 Fan Control Daemon (OpenWrt / RPi 5)
# AUTHOR: ciwga
# ==============================================================================

set -u
set -e
export LC_ALL=C

readonly CHIP_ADDR="0x1a"
readonly REG_FAN="0x80"
readonly LOCK_DIR="/var/run/argon_fan.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly STATUS_FILE="/var/run/argon_fan.status"
readonly VERSION_FILE="/etc/argon_version"

readonly POLL_INTERVAL=5
readonly HEARTBEAT_INTERVAL=60

# State Variables
SENSOR_ERR_STATE=0
I2C_ERR_STATE=0
I2C_CONSEC_ERRORS=0
CURRENT_LEVEL=0
CURRENT_HEX=""
LAST_WRITE_TIME=0
DETECTED_BUS=""
THERMAL_ZONE_PATH=""
CRIT_COUNTER=0
DAEMON_START_TIME=0
PEAK_TEMP=0
FAN_TEST_FLAG=0

# Global Log Level
GLOBAL_LOG_LEVEL=1

# Read installed version from file written by postinst
INSTALLED_VERSION="unknown"
if [ -r "$VERSION_FILE" ]; then
    read -r INSTALLED_VERSION < "$VERSION_FILE" 2>/dev/null || INSTALLED_VERSION="unknown"
fi

# Function: get_uptime
# Returns system uptime in whole seconds from /proc/uptime (no subshell).
get_uptime() {
    local up
    if [ -r /proc/uptime ]; then
        read -r up _ < /proc/uptime
        echo "${up%%.*}"
    else
        date +%s
    fi
}

# Logging functions with level-gated info
log_info() { 
    if [ "$GLOBAL_LOG_LEVEL" = "1" ]; then
        logger -t argon_daemon -p daemon.notice "[INFO] $1"
    fi
}
log_err() { logger -t argon_daemon -p daemon.err "[ERROR] $1"; }
log_crit() { logger -t argon_daemon -p daemon.crit "[CRITICAL] $1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then exit 1; fi
}

# Function: acquire_lock
# Atomic mkdir-based lock with stale PID recovery via kill -0.
# Sets restrictive permissions on PID file (owner-only read/write).
acquire_lock() {
    if mkdir "$LOCK_DIR" >/dev/null 2>&1; then
        echo $$ > "$PID_FILE"
        chmod 0600 "$PID_FILE"
        return 0
    else
        if [ -f "$PID_FILE" ]; then
            local old_pid
            read -r old_pid < "$PID_FILE" 2>/dev/null || old_pid=""
            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                log_err "Another instance (PID $old_pid) is running. Exiting."
                exit 1
            fi
            log_info "Reclaiming stale lock from dead PID ${old_pid:-unknown}."
            rm -f "$PID_FILE"
            rmdir "$LOCK_DIR" 2>/dev/null || true
            if mkdir "$LOCK_DIR" >/dev/null 2>&1; then
                echo $$ > "$PID_FILE"
                chmod 0600 "$PID_FILE"
                return 0
            fi
        fi
        log_err "Failed to acquire lock. Exiting."
        exit 1
    fi
}

# Function: find_thermal_source
# Searches known thermal zone types, falls back to thermal_zone0.
find_thermal_source() {
    local zone type_val found_path=""
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -e "$zone/type" ] || continue
        read -r type_val < "$zone/type" 2>/dev/null || continue
        case "$type_val" in
            "cpu-thermal"|"soc-thermal"|"x86_pkg_temp"|"bcm2835_thermal")
                found_path="$zone/temp"; break ;;
        esac
    done
    if [ -z "$found_path" ]; then
        if [ -f "/sys/class/thermal/thermal_zone0/temp" ]; then found_path="/sys/class/thermal/thermal_zone0/temp"
        else return 1; fi
    fi
    echo "$found_path"
    return 0
}

# Function: find_i2c_bus
# Scans /dev/i2c-* for the Argon MCU at address 0x1a.
find_i2c_bus() {
    local dev bus_num found
    for dev in /dev/i2c-*; do
        [ -e "$dev" ] || continue
        bus_num="${dev##*-}"
        found=$(i2cdetect -y -r "$bus_num" 2>/dev/null | awk 'BEGIN { found=0 } { for(i=2; i<=NF; i++) { if($i == "1a" || $i == "UU") { found=1; exit } } } END { print found }')
        if [ "$found" -eq 1 ]; then echo "$bus_num"; return 0; fi
    done
    return 1
}

# Function: i2c_write
# Safe I2C write wrapper with error state tracking and consecutive error counter.
i2c_write() {
    local bus="$1" reg="$2" val="$3"
    if ! i2cset -y -f "$bus" "$CHIP_ADDR" "$reg" "$val" >/dev/null 2>&1; then
        I2C_CONSEC_ERRORS=$((I2C_CONSEC_ERRORS + 1))
        if [ "$I2C_ERR_STATE" -eq 0 ]; then log_err "I2C Error! Bus: $bus, Reg: $reg, Val: $val"; I2C_ERR_STATE=1; fi
        return 1
    else
        if [ "$I2C_ERR_STATE" -eq 1 ]; then
            log_info "I2C recovered after $I2C_CONSEC_ERRORS errors."
            I2C_ERR_STATE=0
        fi
        I2C_CONSEC_ERRORS=0
        return 0
    fi
}

# ==============================================================================
# SIGUSR1 Handler: Fan Test
# When the LuCI frontend sends SIGUSR1, the daemon runs the fan at 100% for
# 3 seconds, then resumes normal operation. This allows hardware verification
# without restarting the daemon or changing UCI config.
# Implementation: Just sets a flag, the main loop handles the actual I2C write.
# ==============================================================================
handle_fan_test() {
    FAN_TEST_FLAG=1
}
trap handle_fan_test USR1

# ==============================================================================
# cleanup(): Writes 0x00 to fan MCU on exit.
#
# BUG FIX: Previously wrote 0x37 (55%) which caused the Argon ONE V3 MCU to
# keep the fan spinning after poweroff (MCU has standby power rail).
# ==============================================================================
cleanup() {
    set +e 
    if [ -n "${DETECTED_BUS:-}" ]; then
        i2c_write "$DETECTED_BUS" "$REG_FAN" "0x00"
        log_info "Cleanup: Fan OFF (0x00)."
    fi
    rm -f "$PID_FILE" "$STATUS_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
    exit 0
}

trap cleanup EXIT TERM INT HUP
check_root
acquire_lock

set +e
THERMAL_ZONE_PATH=$(find_thermal_source)
DETECTED_BUS=$(find_i2c_bus)
set -e 

if [ -z "$THERMAL_ZONE_PATH" ] || [ -z "$DETECTED_BUS" ]; then
    log_err "Hardware init failed: thermal=${THERMAL_ZONE_PATH:-none}, i2c=${DETECTED_BUS:-none}"
    rm -f "$PID_FILE" && rmdir "$LOCK_DIR" 2>/dev/null
    exit 1
fi

log_info "Daemon v${INSTALLED_VERSION} starting: bus=$DETECTED_BUS, thermal=$THERMAL_ZONE_PATH"

# Initialize IPC status file
printf '{"mode":"loading","level":0,"temp":0,"speed":0,"active_speed":0,"night":0,"night_end":"","version":"%s","uptime":0,"peak":0,"i2c_bus":"%s"}\n' "$INSTALLED_VERSION" "$DETECTED_BUS" > "${STATUS_FILE}.tmp"
mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

# Startup self-test: brief fan pulse to confirm I2C works
i2c_write "$DETECTED_BUS" "$REG_FAN" "0x64"
sleep 1
i2c_write "$DETECTED_BUS" "$REG_FAN" "0x00"

LAST_WRITE_TIME=$(get_uptime)
DAEMON_START_TIME=$(get_uptime)

# ==============================================================================
# CONFIGURATION INGESTION
# Read once at startup. procd restarts daemon on UCI changes.
# ==============================================================================

UCI_MODE=$(uci -q get argononev3.config.mode || echo "auto")
UCI_SPEED=$(uci -q get argononev3.config.manual_speed || echo "50")
GLOBAL_LOG_LEVEL=$(uci -q get argononev3.config.log_level || echo "1")

UCI_SHUTDOWN_EN=$(uci -q get argononev3.config.shutdown_enabled || echo "1")
UCI_SHUTDOWN_TEMP=$(uci -q get argononev3.config.shutdown_temp || echo "85")

UCI_THRESH_HIGH=$(uci -q get argononev3.config.temp_high || echo "72")
UCI_THRESH_MED=$(uci -q get argononev3.config.temp_med || echo "65")
UCI_THRESH_LOW=$(uci -q get argononev3.config.temp_low || echo "58")
UCI_THRESH_QUIET=$(uci -q get argononev3.config.temp_quiet || echo "50")
DYNAMIC_HYST=$(uci -q get argononev3.config.hysteresis || echo "3")

UCI_SPEED_HIGH=$(uci -q get argononev3.config.speed_high || echo "100")
UCI_SPEED_MED=$(uci -q get argononev3.config.speed_med || echo "75")
UCI_SPEED_LOW=$(uci -q get argononev3.config.speed_low || echo "50")
UCI_SPEED_QUIET=$(uci -q get argononev3.config.speed_quiet || echo "25")

UCI_NIGHT_EN=$(uci -q get argononev3.config.night_enabled || echo "0")
UCI_NIGHT_START=$(uci -q get argononev3.config.night_start || echo "23")
UCI_NIGHT_END=$(uci -q get argononev3.config.night_end || echo "07")
UCI_NIGHT_MAX=$(uci -q get argononev3.config.night_max || echo "30")

# ==============================================================================
# UCI CONFIG VALIDATION (Defense-in-depth)
# Even though the LuCI frontend validates, a user could edit /etc/config
# directly via SSH. Ensure threshold ordering and range sanity at daemon level.
# If invalid, fall back to safe defaults and log a warning.
# ==============================================================================
validate_range() {
    local val="$1" min="$2" max="$3" fallback="$4" name="$5"
    case "$val" in ''|*[!0-9]*) val="$fallback" ;; esac
    if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
        log_err "Config validation: $name=$val out of range ($min-$max). Using $fallback."
        echo "$fallback"
    else
        echo "$val"
    fi
}

UCI_THRESH_QUIET=$(validate_range "$UCI_THRESH_QUIET" 30 90 50 "temp_quiet")
UCI_THRESH_LOW=$(validate_range "$UCI_THRESH_LOW" 30 90 58 "temp_low")
UCI_THRESH_MED=$(validate_range "$UCI_THRESH_MED" 30 90 65 "temp_med")
UCI_THRESH_HIGH=$(validate_range "$UCI_THRESH_HIGH" 30 90 72 "temp_high")
UCI_SHUTDOWN_TEMP=$(validate_range "$UCI_SHUTDOWN_TEMP" 70 95 85 "shutdown_temp")
DYNAMIC_HYST=$(validate_range "$DYNAMIC_HYST" 1 10 3 "hysteresis")
UCI_SPEED=$(validate_range "$UCI_SPEED" 0 100 50 "manual_speed")
UCI_SPEED_HIGH=$(validate_range "$UCI_SPEED_HIGH" 0 100 100 "speed_high")
UCI_SPEED_MED=$(validate_range "$UCI_SPEED_MED" 0 100 75 "speed_med")
UCI_SPEED_LOW=$(validate_range "$UCI_SPEED_LOW" 0 100 50 "speed_low")
UCI_SPEED_QUIET=$(validate_range "$UCI_SPEED_QUIET" 0 100 25 "speed_quiet")
UCI_NIGHT_MAX=$(validate_range "$UCI_NIGHT_MAX" 0 100 30 "night_max")

# Enforce threshold ordering: quiet < low < med < high < shutdown
if [ "$UCI_THRESH_QUIET" -ge "$UCI_THRESH_LOW" ] || \
   [ "$UCI_THRESH_LOW" -ge "$UCI_THRESH_MED" ] || \
   [ "$UCI_THRESH_MED" -ge "$UCI_THRESH_HIGH" ]; then
    log_err "Config validation: Threshold ordering invalid (quiet=$UCI_THRESH_QUIET >= low=$UCI_THRESH_LOW >= med=$UCI_THRESH_MED >= high=$UCI_THRESH_HIGH). Resetting to defaults."
    UCI_THRESH_QUIET=50; UCI_THRESH_LOW=58; UCI_THRESH_MED=65; UCI_THRESH_HIGH=72
fi

if [ "$UCI_SHUTDOWN_EN" = "1" ] && [ "$UCI_SHUTDOWN_TEMP" -le "$UCI_THRESH_HIGH" ]; then
    log_err "Config validation: shutdown_temp ($UCI_SHUTDOWN_TEMP) <= temp_high ($UCI_THRESH_HIGH). Adjusting to $((UCI_THRESH_HIGH + 10))."
    UCI_SHUTDOWN_TEMP=$((UCI_THRESH_HIGH + 10))
    # Clamp to max 95
    if [ "$UCI_SHUTDOWN_TEMP" -gt 95 ]; then UCI_SHUTDOWN_TEMP=95; fi
fi

# Pre-calculate hex values (avoids printf subshells in hot loop)
HEX_HIGH=$(printf "0x%02x" "$UCI_SPEED_HIGH")
HEX_MED=$(printf "0x%02x" "$UCI_SPEED_MED")
HEX_LOW=$(printf "0x%02x" "$UCI_SPEED_LOW")
HEX_QUIET=$(printf "0x%02x" "$UCI_SPEED_QUIET")
HEX_OFF="0x00"

log_info "Config: mode=$UCI_MODE, curve=${UCI_THRESH_QUIET}/${UCI_THRESH_LOW}/${UCI_THRESH_MED}/${UCI_THRESH_HIGH}C, shutdown=$UCI_SHUTDOWN_EN/${UCI_SHUTDOWN_TEMP}C"

# Set restrictive umask for status file (readable by owner+group, not world-writable)
umask 0022

# ==============================================================================
# MAIN CONTROL LOOP
# ==============================================================================
while true; do

    # ---- Fan Test Handler (SIGUSR1) ----
    if [ "$FAN_TEST_FLAG" -eq 1 ]; then
        FAN_TEST_FLAG=0
        log_info "Fan test triggered via signal. Running 100% for 3 seconds."
        i2c_write "$DETECTED_BUS" "$REG_FAN" "0x64"
        sleep 3
        # Force re-evaluation by clearing current hex so next iteration writes correct value
        CURRENT_HEX=""
        log_info "Fan test complete. Resuming normal operation."
    fi

    # ---- Temperature Reading ----
    if read -r RAW_TEMP < "$THERMAL_ZONE_PATH" 2>/dev/null; then :; else RAW_TEMP="-1"; fi

    if [ -z "$RAW_TEMP" ] || [ "$RAW_TEMP" -lt 0 ]; then
         TEMP=65
         if [ "$SENSOR_ERR_STATE" -eq 0 ]; then 
             log_err "Sensor read failed! Fallback 65C."
             SENSOR_ERR_STATE=1
         fi
    else
         TEMP=$((RAW_TEMP / 1000))
         if [ "$SENSOR_ERR_STATE" -eq 1 ]; then
             log_info "Sensor recovered."
             SENSOR_ERR_STATE=0
         fi
    fi

    # Peak temperature tracking (single comparison, zero overhead)
    if [ "$TEMP" -gt "$PEAK_TEMP" ]; then PEAK_TEMP=$TEMP; fi

    # ---- I2C Bus Re-detection ----
    if [ "$I2C_CONSEC_ERRORS" -ge 10 ]; then
        log_err "I2C dead after $I2C_CONSEC_ERRORS errors. Re-detecting bus..."
        set +e
        NEW_BUS=$(find_i2c_bus)
        set -e
        if [ -n "$NEW_BUS" ]; then
            DETECTED_BUS="$NEW_BUS"
            I2C_CONSEC_ERRORS=0
            I2C_ERR_STATE=0
            log_info "I2C re-detected on bus $DETECTED_BUS."
        else
            I2C_CONSEC_ERRORS=0
        fi
    fi

    # ---- Night Mode ----
    IS_NIGHT=0
    if [ "$UCI_NIGHT_EN" = "1" ]; then
        CH=$(date +%H)
        CH=${CH#0}; NS=${UCI_NIGHT_START#0}; NE=${UCI_NIGHT_END#0}
        [ -z "$CH" ] && CH=0; [ -z "$NS" ] && NS=0; [ -z "$NE" ] && NE=0
        
        if [ "$NS" -gt "$NE" ]; then
            if [ "$CH" -ge "$NS" ] || [ "$CH" -lt "$NE" ]; then IS_NIGHT=1; fi
        elif [ "$NS" -lt "$NE" ]; then
            if [ "$CH" -ge "$NS" ] && [ "$CH" -lt "$NE" ]; then IS_NIGHT=1; fi
        else
            IS_NIGHT=1
        fi
    fi

    ACTIVE_SPEED=0

    # ---- Critical Thermal Shutdown ----
    if [ "$UCI_SHUTDOWN_EN" = "1" ] && [ "$TEMP" -ge "$UCI_SHUTDOWN_TEMP" ]; then
        CRIT_COUNTER=$((CRIT_COUNTER + 1))
        log_crit "Thermal! ${TEMP}C >= ${UCI_SHUTDOWN_TEMP}C (${CRIT_COUNTER}/3)"
        
        i2c_write "$DETECTED_BUS" "$REG_FAN" "0x64"
        CURRENT_HEX="0x64"; ACTIVE_SPEED=100; IS_NIGHT=0
        
        if [ "$CRIT_COUNTER" -ge 3 ]; then
            log_crit "EMERGENCY POWEROFF!"
            i2c_write "$DETECTED_BUS" "$REG_FAN" "0x64"
            sync; poweroff; sleep 30
        fi
    else
        CRIT_COUNTER=0
    fi

    # ---- Normal Fan Control ----
    if [ "$CRIT_COUNTER" -eq 0 ]; then
        if [ "$UCI_MODE" = "manual" ]; then
            NEW_LEVEL=-1
            TARGET_HEX=$(printf "0x%02x" "$UCI_SPEED")
            ACTIVE_SPEED="$UCI_SPEED"
        else
            if   [ "$TEMP" -ge "$UCI_THRESH_HIGH" ];  then TARGET=4
            elif [ "$TEMP" -ge "$UCI_THRESH_MED" ];   then TARGET=3
            elif [ "$TEMP" -ge "$UCI_THRESH_LOW" ];   then TARGET=2
            elif [ "$TEMP" -ge "$UCI_THRESH_QUIET" ]; then TARGET=1
            else TARGET=0; fi

            # Hysteresis: instant ramp-up, delayed ramp-down
            if [ "$TARGET" -gt "$CURRENT_LEVEL" ]; then
                NEW_LEVEL=$TARGET
            elif [ "$TARGET" -lt "$CURRENT_LEVEL" ]; then
                case "$CURRENT_LEVEL" in
                    4) BASE=$UCI_THRESH_HIGH ;; 3) BASE=$UCI_THRESH_MED ;;
                    2) BASE=$UCI_THRESH_LOW ;; 1) BASE=$UCI_THRESH_QUIET ;; *) BASE=0 ;;
                esac
                if [ "$TEMP" -le $((BASE - DYNAMIC_HYST)) ]; then NEW_LEVEL=$TARGET
                else NEW_LEVEL=$CURRENT_LEVEL; fi
            else
                NEW_LEVEL=$CURRENT_LEVEL
            fi

            case "$NEW_LEVEL" in
                4) TARGET_HEX="$HEX_HIGH"; ACTIVE_SPEED="$UCI_SPEED_HIGH" ;;
                3) TARGET_HEX="$HEX_MED"; ACTIVE_SPEED="$UCI_SPEED_MED" ;;
                2) TARGET_HEX="$HEX_LOW"; ACTIVE_SPEED="$UCI_SPEED_LOW" ;;
                1) TARGET_HEX="$HEX_QUIET"; ACTIVE_SPEED="$UCI_SPEED_QUIET" ;;
                *) TARGET_HEX="$HEX_OFF"; ACTIVE_SPEED="0" ;;
            esac
        fi

        # Night mode cap
        if [ "$IS_NIGHT" -eq 1 ] && [ "$ACTIVE_SPEED" -gt "$UCI_NIGHT_MAX" ]; then
            ACTIVE_SPEED="$UCI_NIGHT_MAX"
            TARGET_HEX=$(printf "0x%02x" "$ACTIVE_SPEED")
        fi

        # Write I2C on state change or periodic heartbeat
        CURRENT_TIME=$(get_uptime)
        TIME_DIFF=$((CURRENT_TIME - LAST_WRITE_TIME))
        
        if [ "$TARGET_HEX" != "$CURRENT_HEX" ] || [ "$TIME_DIFF" -ge "$HEARTBEAT_INTERVAL" ]; then
            if i2c_write "$DETECTED_BUS" "$REG_FAN" "$TARGET_HEX"; then
                if [ "$TARGET_HEX" != "$CURRENT_HEX" ]; then
                    log_info "Temp: ${TEMP}C -> ${ACTIVE_SPEED}% ($TARGET_HEX)"
                fi
                CURRENT_HEX="$TARGET_HEX"
                CURRENT_LEVEL="$NEW_LEVEL"
                LAST_WRITE_TIME=$CURRENT_TIME
            fi
        fi
    fi

    # ---- IPC Status File (atomic write) ----
    DAEMON_UPTIME=$(( $(get_uptime) - DAEMON_START_TIME ))
    printf '{"mode":"%s","level":%d,"temp":%d,"speed":%d,"active_speed":%d,"night":%d,"night_end":"%s","version":"%s","uptime":%d,"peak":%d,"i2c_bus":"%s"}\n' \
        "$UCI_MODE" "${NEW_LEVEL:-4}" "$TEMP" "$UCI_SPEED" "$ACTIVE_SPEED" "$IS_NIGHT" \
        "$UCI_NIGHT_END" "$INSTALLED_VERSION" "$DAEMON_UPTIME" "$PEAK_TEMP" "$DETECTED_BUS" \
        > "${STATUS_FILE}.tmp"
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    sleep "$POLL_INTERVAL"
done