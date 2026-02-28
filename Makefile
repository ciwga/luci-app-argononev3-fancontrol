# ==============================================================================
# FILE: Makefile
# DESCRIPTION: OpenWrt Package Build Script for Argon ONE V3 Fan Control
# AUTHOR: ciwga
# ==============================================================================

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-argononev3-fancontrol
PKG_VERSION:=3.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=ciwga
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

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

define Build/Compile
endef

define Package/luci-app-argononev3-fancontrol/conffiles
/etc/config/argononev3
endef

define Package/luci-app-argononev3-fancontrol/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/root/usr/bin/argon_fan_control.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./files/root/usr/bin/argon_update.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./files/root/usr/bin/argon_fan_test.sh $(1)/usr/bin/
	
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
	killall -9 argon_fan_control.sh 2>/dev/null || true
	rm -f /var/run/argon_fan.status /var/run/argon_fan.lock/pid 2>/dev/null || true
	rmdir /var/run/argon_fan.lock 2>/dev/null || true
	echo "$(PKG_VERSION)-$(PKG_RELEASE)" > /etc/argon_version
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/argon_daemon enable
	/etc/init.d/argon_daemon start
	exit 0
}
endef

define Package/luci-app-argononev3-fancontrol/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/argon_daemon stop 2>/dev/null || true
	for dev in /dev/i2c-*; do
		[ -e "$$dev" ] || continue
		bus="$${dev##*-}"
		if i2cdetect -y -r "$$bus" 2>/dev/null | grep -q "1a"; then
			i2cset -y -f "$$bus" 0x1a 0x80 0x00 2>/dev/null || true
			break
		fi
	done
	/etc/init.d/argon_daemon disable 2>/dev/null || true
	exit 0
}
endef

define Package/luci-app-argononev3-fancontrol/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	killall -9 argon_fan_control.sh 2>/dev/null || true
	killall -9 argon_update.sh 2>/dev/null || true
	rm -f /etc/config/argononev3
	rm -f /etc/config/argononev3-opkg
	rm -f /etc/config/argononev3.bak
	rm -f /etc/argon_version
	rm -f /var/run/argon_fan.status /var/run/argon_fan.status.tmp
	rm -f /var/run/argon_fan.lock/pid
	rmdir /var/run/argon_fan.lock 2>/dev/null || true
	rm -f /tmp/argon_update.ipk /tmp/argon_update_install.log /tmp/argononev3_latest.ipk
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	exit 0
}
endef

$(eval $(call BuildPackage,luci-app-argononev3-fancontrol))