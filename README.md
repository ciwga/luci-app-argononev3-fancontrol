# Argon ONE V3 Fan Control for OpenWrt (Raspberry Pi 5)

![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)
![Version](https://img.shields.io/badge/Version-3.0.0-orange.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

A professional, production-grade LuCI interface and lightweight background daemon for managing the Argon ONE V3 cooling fan natively on OpenWrt.

## 🚀 What's New in v3.0.0
* **Smart UI Dashboard**: Now includes a real-time sparkline graph for temperature trends, daemon uptime tracking, and peak temperature recording.
* **Quick Cooling Presets**: Instantly apply optimized fan curves with one click (*Silent, Balanced, Performance*).
* **Config Import/Export**: Easily backup or share your custom fan curves and settings as a JSON file.
* **Hardware Fan Test**: A dedicated diagnostic button to safely spin the fan at 100% for 3 seconds via SIGUSR1 signals.
* **Smart OTA Updater**: The built-in updater now compares versions and prevents redundant installations, displaying real-time upgrade status.
* **I2C Auto-Recovery & True Poweroff**: Daemon now automatically recovers from I2C bus lockups and guarantees the fan completely turns off (`0x00`) during system halts.

## ✨ Core Features

* **Live Telemetry Dashboard**: A sleek, dark-mode, asynchronous UI that displays real-time statistics without requiring a page refresh.
* **Hardware-Level Precision**: Native I2C communication tailored specifically for the Argon ONE V3 hardware register (`0x80`).
* **Custom Cooling Curve**: Fully dynamic temperature thresholds, fan speeds, and hysteresis control.
* **Night Mode (Quiet Hours)**: Define specific hours to cap the maximum fan speed, ensuring a silent environment while you sleep.
* **Critical Thermal Shutdown**: A dedicated hardware safety mechanism that gracefully powers off the Pi 5 if temperatures reach a critical limit (e.g., `85°C`).
* **Zero-Overhead Daemon**: Written in pure `ash` shell, requiring no heavy C libraries, resulting in zero CPU bloat and no memory leaks.

## 📦 Installation

### Option 1: Automated Installation (Recommended)
We provide a robust automated installation script that securely cleans up old versions, enables the required I2C bus (`/boot/config.txt`), installs dependencies, and sets up the daemon.

Run the following one-liner via SSH:
```bash
wget -qO - https://raw.githubusercontent.com/ciwga/luci-app-argononev3-fancontrol/main/install.sh | sh
```
*Note: A system reboot is required after the first installation to activate the I2C bus.*

### Option 2: Manual Installation
1. Enable I2C by adding `dtparam=i2c_arm=on` to your `/boot/config.txt` and **reboot**.
2. Install the hardware dependency:
   ```bash
   opkg update && opkg install i2c-tools
   ```
3. Download the latest `.ipk` from the [Releases](https://github.com/ciwga/luci-app-argononev3-fancontrol/releases) page.
4. Upload to your router and install:
   ```bash
   opkg install /tmp/luci-app-argononev3-fancontrol_*.ipk
   ```

## ⚙️ Configuration

Navigate to your OpenWrt LuCI web interface:
**LuCI → Services → Argon ONE V3 Fan**

The configuration page is divided into five intuitive tabs:
1. **General**: Operation mode (Auto/Manual) and logging verbosity.
2. **Cooling Curve**: Quick Presets, dynamic temperature triggers, fan speeds, and hysteresis.
3. **Night Mode**: Quiet hours scheduling and speed caps.
4. **Safety**: Critical thermal shutdown threshold setup.
5. **About & Updates**: OTA version checking, Config Export/Import, and manual daemon restart.

## 📝 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
