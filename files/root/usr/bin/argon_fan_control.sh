#!/bin/sh

# ==============================================================================
# FILE: /usr/bin/argon_fan_control.sh
# DESCRIPTION: Argon ONE V3 Fan Control Daemon (OpenWrt / RPi 5 Fix)
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

readonly POLL_INTERVAL=5
readonly HEARTBEAT_INTERVAL=60

# State Variables
SENSOR_ERR_STATE=0
I2C_ERR_STATE=0
CURRENT_LEVEL=0
CURRENT_HEX=""
LAST_WRITE_TIME=0
DETECTED_BUS=""
THERMAL_ZONE_PATH=""
CRIT_COUNTER=0

# Global Log Level (Updated dynamically in the loop)
GLOBAL_LOG_LEVEL=1

# Function to get exact uptime safely
get_uptime() {
    local up
    if [ -r /proc/uptime ]; then
        read -r up _ < /proc/uptime
        echo "${up%%.*}"
    else
        date +%s
    fi
}

# Standardized logging functions
log_info() { 
    if [ "$GLOBAL_LOG_LEVEL" = "1" ]; then
        logger -t argon_daemon -p daemon.notice "[INFO] $1"
    fi
}
log_err() { logger -t argon_daemon -p daemon.err "[ERROR] $1"; }
log_crit() { logger -t argon_daemon -p daemon.crit "[CRITICAL] $1"; }

# Privilege verification
check_root() {
    if [ "$(id -u)" -ne 0 ]; then exit 1; fi
}

# Atomic locking mechanism to prevent race conditions
acquire_lock() {
    if mkdir "$LOCK_DIR" >/dev/null 2>&1; then
        echo $$ > "$PID_FILE"
        return 0
    else
        if [ -f "$PID_FILE" ]; then
            rm -f "$PID_FILE"
            rmdir "$LOCK_DIR" 2>/dev/null || true
            if mkdir "$LOCK_DIR" >/dev/null 2>&1; then
                echo $$ > "$PID_FILE"
                return 0
            fi
        fi
        exit 1
    fi
}

# Automatically determine the correct CPU thermal zone
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

# Automatically detect the active I2C bus for the Argon MCU
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

# Wrapper for safe I2C register writes
i2c_write() {
    local bus="$1" reg="$2" val="$3"
    if ! i2cset -y -f "$bus" "$CHIP_ADDR" "$reg" "$val" >/dev/null 2>&1; then
        if [ "$I2C_ERR_STATE" -eq 0 ]; then log_err "I2C Error! Bus: $bus, Reg: $reg, Val: $val"; I2C_ERR_STATE=1; fi
        return 1
    else
        if [ "$I2C_ERR_STATE" -eq 1 ]; then I2C_ERR_STATE=0; fi
        return 0
    fi
}

# Graceful exit handler
cleanup() {
    set +e 
    if [ -n "${DETECTED_BUS:-}" ]; then i2c_write "$DETECTED_BUS" "$REG_FAN" "0x37"; fi
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
    rm -f "$PID_FILE" && rmdir "$LOCK_DIR" 2>/dev/null
    exit 1
fi

# Initialize IPC status file safely
printf '{"mode":"loading","level":0,"temp":0,"speed":0,"active_speed":0,"night":0}\n' > "${STATUS_FILE}.tmp"
mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

i2c_write "$DETECTED_BUS" "$REG_FAN" "0x64"
sleep 1
i2c_write "$DETECTED_BUS" "$REG_FAN" "0x00"

LAST_WRITE_TIME=$(get_uptime)

# ==============================================================================
# CONFIGURATION INGESTION (Memory & CPU Optimization)
# Readings are done ONCE at startup. If UCI configuration changes, 
# OpenWrt procd will cleanly restart this daemon via procd_add_reload_trigger.
# This prevents thousands of subshells from spawning in the while loop.
# ==============================================================================

# General Settings
UCI_MODE=$(uci -q get argononev3.config.mode || echo "auto")
UCI_SPEED=$(uci -q get argononev3.config.manual_speed || echo "55")
GLOBAL_LOG_LEVEL=$(uci -q get argononev3.config.log_level || echo "1")

# Critical Shutdown Settings
UCI_SHUTDOWN_EN=$(uci -q get argononev3.config.shutdown_enabled || echo "0")
UCI_SHUTDOWN_TEMP=$(uci -q get argononev3.config.shutdown_temp || echo "85")

# Dynamic Custom Temperature Curve & Hysteresis
UCI_THRESH_HIGH=$(uci -q get argononev3.config.temp_high || echo "60")
UCI_THRESH_MED=$(uci -q get argononev3.config.temp_med || echo "55")
UCI_THRESH_LOW=$(uci -q get argononev3.config.temp_low || echo "45")
UCI_THRESH_QUIET=$(uci -q get argononev3.config.temp_quiet || echo "40")
DYNAMIC_HYST=$(uci -q get argononev3.config.hysteresis || echo "4")

# Dynamic Fan Speeds
UCI_SPEED_HIGH=$(uci -q get argononev3.config.speed_high || echo "100")
UCI_SPEED_MED=$(uci -q get argononev3.config.speed_med || echo "55")
UCI_SPEED_LOW=$(uci -q get argononev3.config.speed_low || echo "25")
UCI_SPEED_QUIET=$(uci -q get argononev3.config.speed_quiet || echo "10")

# Night Mode Settings
UCI_NIGHT_EN=$(uci -q get argononev3.config.night_enabled || echo "0")
UCI_NIGHT_START=$(uci -q get argononev3.config.night_start || echo "23")
UCI_NIGHT_END=$(uci -q get argononev3.config.night_end || echo "07")
UCI_NIGHT_MAX=$(uci -q get argononev3.config.night_max || echo "25")

# Hex Conversions Pre-calculated
HEX_HIGH=$(printf "0x%02x" "$UCI_SPEED_HIGH")
HEX_MED=$(printf "0x%02x" "$UCI_SPEED_MED")
HEX_LOW=$(printf "0x%02x" "$UCI_SPEED_LOW")
HEX_QUIET=$(printf "0x%02x" "$UCI_SPEED_QUIET")
HEX_OFF="0x00"

while true; do
    # Temperature Reading
    if read -r RAW_TEMP < "$THERMAL_ZONE_PATH" 2>/dev/null; then :; else RAW_TEMP="-1"; fi

    if [ -z "$RAW_TEMP" ] || [ "$RAW_TEMP" -lt 0 ]; then
         TEMP=65
         if [ "$SENSOR_ERR_STATE" -eq 0 ]; then 
             log_err "Temperature sensor read failed! Using fallback 65C."
             SENSOR_ERR_STATE=1
         fi
    else
         TEMP=$((RAW_TEMP / 1000))
         if [ "$SENSOR_ERR_STATE" -eq 1 ]; then SENSOR_ERR_STATE=0; fi
    fi

    # Night Mode Logic Calculation (Optimized: No awk/date subshell overhead)
    IS_NIGHT=0
    if [ "$UCI_NIGHT_EN" = "1" ]; then
        CH=$(date +%H)
        # Safely remove leading zeros to prevent octal arithmetic errors
        CH=${CH#0} 
        NS=${UCI_NIGHT_START#0}
        NE=${UCI_NIGHT_END#0}
        
        # Fallback handling
        [ -z "$CH" ] && CH=0
        [ -z "$NS" ] && NS=0
        [ -z "$NE" ] && NE=0
        
        if [ "$NS" -gt "$NE" ]; then
            if [ "$CH" -ge "$NS" ] || [ "$CH" -lt "$NE" ]; then IS_NIGHT=1; fi
        elif [ "$NS" -lt "$NE" ]; then
            if [ "$CH" -ge "$NS" ] && [ "$CH" -lt "$NE" ]; then IS_NIGHT=1; fi
        else
            IS_NIGHT=1
        fi
    fi

    ACTIVE_SPEED=0

    # CRITICAL THERMAL SHUTDOWN LOGIC
    if [ "$UCI_SHUTDOWN_EN" = "1" ] && [ "$TEMP" -ge "$UCI_SHUTDOWN_TEMP" ]; then
        CRIT_COUNTER=$((CRIT_COUNTER + 1))
        log_crit "Thermal Warning! Temp: ${TEMP}C >= Threshold: ${UCI_SHUTDOWN_TEMP}C"
        
        i2c_write "$DETECTED_BUS" "$REG_FAN" "0x64"
        CURRENT_HEX="0x64"
        ACTIVE_SPEED=100
        IS_NIGHT=0
        
        if [ "$CRIT_COUNTER" -ge 3 ]; then
            log_crit "EMERGENCY: Executing safe poweroff to protect hardware!"
            sync; poweroff; sleep 30
        fi
    else
        CRIT_COUNTER=0
    fi

    # Normal Fan Control Logic
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

            if [ "$TARGET" -gt "$CURRENT_LEVEL" ]; then
                NEW_LEVEL=$TARGET
            elif [ "$TARGET" -lt "$CURRENT_LEVEL" ]; then
                case "$CURRENT_LEVEL" in
                    4) BASE=$UCI_THRESH_HIGH ;; 
                    3) BASE=$UCI_THRESH_MED ;; 
                    2) BASE=$UCI_THRESH_LOW ;; 
                    1) BASE=$UCI_THRESH_QUIET ;; 
                    *) BASE=0 ;;
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

        # APPLY NIGHT MODE CAP
        if [ "$IS_NIGHT" -eq 1 ] && [ "$ACTIVE_SPEED" -gt "$UCI_NIGHT_MAX" ]; then
            ACTIVE_SPEED="$UCI_NIGHT_MAX"
            TARGET_HEX=$(printf "0x%02x" "$ACTIVE_SPEED")
        fi

        CURRENT_TIME=$(get_uptime)
        TIME_DIFF=$((CURRENT_TIME - LAST_WRITE_TIME))
        
        if [ "$TARGET_HEX" != "$CURRENT_HEX" ] || [ "$TIME_DIFF" -ge "$HEARTBEAT_INTERVAL" ]; then
            if i2c_write "$DETECTED_BUS" "$REG_FAN" "$TARGET_HEX"; then
                if [ "$TARGET_HEX" != "$CURRENT_HEX" ]; then
                    log_info "Temp: ${TEMP}C -> Speed changed to ${ACTIVE_SPEED}% ($TARGET_HEX)"
                fi
                CURRENT_HEX="$TARGET_HEX"
                CURRENT_LEVEL="$NEW_LEVEL"
                LAST_WRITE_TIME=$CURRENT_TIME
            fi
        fi
    fi

    # Write IPC state file atomically to a memory-backed tmpfs (/var/run/) 
    # to prevent partial reads by the LuCI JS frontend without degrading flash memory.
    printf '{"mode":"%s","level":%d,"temp":%d,"speed":%d,"active_speed":%d,"night":%d}\n' "$UCI_MODE" "${NEW_LEVEL:-4}" "$TEMP" "$UCI_SPEED" "$ACTIVE_SPEED" "$IS_NIGHT" > "${STATUS_FILE}.tmp"
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    sleep "$POLL_INTERVAL"
done