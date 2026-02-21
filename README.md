# Argon ONE V3 Fan Control for OpenWrt (Raspberry Pi 5)

![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

A professional, production-grade LuCI interface and lightweight background daemon for managing the Argon ONE V3 cooling fan natively on OpenWrt.

## 🚀 Features

* **Live Telemetry Dashboard**: A sleek, dark-mode, asynchronous UI that displays real-time CPU temperature, active fan speed, and daemon status without requiring a page refresh.
* **Hardware-Level Precision**: Native I2C communication tailored specifically for the Argon ONE V3 hardware register (`0x80`), ensuring instant fan response.
* **Custom Cooling Curve**: Fully dynamic temperature thresholds and fan speed percentages configurable directly from the LuCI web interface.
* **Night Mode (Quiet Hours)**: Define specific hours to cap the maximum fan speed, ensuring a silent environment while you sleep.
* **Critical Thermal Shutdown**: A dedicated hardware safety mechanism that gracefully powers off the Raspberry Pi 5 if temperatures reach a user-defined critical limit (e.g., `85°C`), overriding all other settings to prevent silicon damage.
* **Zero-Overhead Daemon**: Written in pure `ash` shell, the background service requires no heavy C libraries (like `glib2`), resulting in zero CPU bloat, no memory leaks, and air-gapped CI/CD build safety.

## 📦 Installation

### Option 1: Automated Installation (Recommended)
We provide an automated installation script that securely enables the required I2C bus on your Raspberry Pi 5 (`/boot/config.txt`), installs the `i2c-tools` dependency, and sets up the daemon.

Run the following one-liner command via SSH on your OpenWrt router:
```bash
wget -qO - https://raw.githubusercontent.com/ciwga/luci-app-argononev3-fancontrol/main/install.sh | sh
```
*Note: A system reboot is required after the first installation to activate the I2C bus.*

### Option 2: Manual Installation
If you prefer to install the `.ipk` package manually or do not want to use the automated script:

1. Enable I2C by adding `dtparam=i2c_arm=on` to your `/boot/config.txt` and **reboot** the device.
2. Install the `i2c-tools` hardware dependency:
   ```bash
   opkg update
   opkg install i2c-tools
   ```
3. Go to the [Releases](https://github.com/ciwga/luci-app-argononev3-fancontrol/releases) page and download the latest `.ipk` file.
4. Upload the package to your OpenWrt router (e.g., via `scp` to `/tmp/`).
5. Install the package using the package manager:
   ```bash
   opkg install /tmp/luci-app-argononev3-fancontrol_*.ipk
   ```
6. Clean up any existing ghost processes and start the new service securely:
   ```bash
   /etc/init.d/argon_daemon stop
   killall -9 argon_fan_control.sh 2>/dev/null
   rm -f /var/run/argon_fan.status /var/run/argon_fan.lock/*
   /etc/init.d/rpcd restart
   /etc/init.d/argon_daemon enable
   /etc/init.d/argon_daemon start
   ```

## ⚙️ Configuration

Navigate to your OpenWrt LuCI web interface:
**LuCI → Services → Argon ONE V3 Fan Control**

The configuration page is divided into four intuitive tabs:
* **General**: Enable/disable the service, select `Auto` or `Manual` mode, and set log verbosity (Verbose/Quiet).
* **Cooling Curve**: Adjust temperature triggers (°C) and their corresponding fan speeds (%). Also includes Hysteresis control to prevent rapid on/off cycling.
* **Night Mode**: Set start/end hours and the maximum allowed fan speed during those hours.
* **Safety**: Enable and configure the critical thermal shutdown threshold.

## 📝 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
