# Argon ONE V3 Fan Control for OpenWrt (Raspberry Pi 5)

![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05+-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%205-red.svg)
![Version](https://img.shields.io/badge/Version-3.0.1-orange.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

A professional, production-grade LuCI interface and lightweight background daemon for managing the Argon ONE V3 cooling fan natively on OpenWrt.

## 🚀 What's New in v3.0.1
* **Universal OpenWrt Support:** Fully compatible with both modern OpenWrt 25.12+ (`apk` package manager) and legacy OpenWrt 24.10 (`opkg`).
* **Dual-Architecture OTA Updates:** The built-in smart updater now automatically detects your system's package manager and seamlessly downloads the correct format (`.apk` or `.ipk`) without user intervention.
* **Smart One-Liner Installer:** The `install.sh` script has been rewritten to dynamically adapt to the target system, safely handling dependencies and format requirements on the fly.
* **Automated Dual-Build CI/CD:** GitHub Actions workflow now natively cross-compiles against both OpenWrt 24.10 and 25.12 SDKs, attaching both verified assets to every release.
* *(Includes all v3.0.0 features: Smart UI Dashboard, Quick Cooling Presets, Config Import/Export, Hardware Fan Test, and I2C Auto-Recovery).*

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

If you prefer to install manually, follow the specific commands for your OpenWrt version:

1. Enable I2C by adding `dtparam=i2c_arm=on` to your `/boot/config.txt` and **reboot**.

2. Download the correct package from the [Releases](https://github.com/ciwga/luci-app-argononev3-fancontrol/releases) page and upload it to your router's `/tmp/` folder:

   * **OpenWrt 25.12+:** Download the `.apk` file.

   * **OpenWrt 24.10:** Download the `.ipk` file.

3. Install the hardware dependency and the package:

**For Modern OpenWrt (25.12+) using `apk`:**

```
apk update
apk add i2c-tools
apk add --force-broken-world /tmp/luci-app-argononev3-fancontrol*.apk

```

**For Legacy OpenWrt (24.10) using `opkg`:**

```
opkg update
opkg install i2c-tools
opkg install --force-maintainer --force-overwrite /tmp/luci-app-argononev3-fancontrol*.ipk

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
