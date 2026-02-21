# ==============================================================================
# FILE: Makefile
# DESCRIPTION: OpenWrt Package Build Script for Argon ONE V3 Fan Control
# AUTHOR: ciwga
# VERSION: 1.0.0
# ==============================================================================

include $(TOPDIR)/rules.mk

# Package Definitions
PKG_NAME:=luci-app-argononev3-fancontrol
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=ciwga
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

# This specifies that it is a standard package format
include $(INCLUDE_DIR)/package.mk

# Package Metadata
define Package/luci-app-argononev3-fancontrol
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=Argon ONE V3 Fan Control Interface
	DEPENDS:=@TARGET_bcm27xx_bcm2712 +i2c-tools
	ARCH:=aarch64_cortex-a76
endef

define Package/luci-app-argononev3-fancontrol/description
	Professional LuCI Interface and background Daemon for controlling 
	the Argon ONE V3 cooling fan on Raspberry Pi 5. 
	Supports automatic temperature-based cooling and secure manual override.
	Built with modern OpenWrt Client-Side Rendering (CSR) architecture.
endef

# Prevents the build system from looking for source code to compile
define Build/Compile
endef

# Marks the UCI configuration as a conffile so it is preserved during upgrades
define Package/luci-app-argononev3-fancontrol/conffiles
/etc/config/argononev3
endef

# Installation Instructions
define Package/luci-app-argononev3-fancontrol/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/root/usr/bin/argon_fan_control.sh $(1)/usr/bin/
	
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/root/etc/init.d/argon_daemon $(1)/etc/init.d/
	
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/root/etc/config/argononev3 $(1)/etc/config/
	
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/root/usr/share/luci/menu.d/luci-app-argononev3.json $(1)/usr/share/luci/menu.d/
	
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/root/usr/share/rpcd/acl.d/luci-app-argononev3.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DATA) ./files/root/www/luci-static/resources/view/argononev3.js $(1)/www/luci-static/resources/view/
endef

define Package/luci-app-argononev3-fancontrol/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache >/dev/null 2>&1
	/etc/init.d/rpcd restart >/dev/null 2>&1
	/etc/init.d/argon_daemon enable
	/etc/init.d/argon_daemon start
	exit 0
}
endef

define Package/luci-app-argononev3-fancontrol/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/argon_daemon stop
	/etc/init.d/argon_daemon disable
	exit 0
}
endef

$(eval $(call BuildPackage,luci-app-argononev3-fancontrol))