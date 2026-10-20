#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default IP
sed -i 's/192.168.1.1/192.168.69.2/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# 确保编译时使用包含 2026-07-08 MTK 扫描修复的源码。
# 修复包括 PartialScan 状态竞态、后台扫描丢包和 5 秒固定等待缩短为 3 秒。
REQUIRED_WIFI_SCAN_FIX="6de7ebc60200ddc1ba50596a50f9f4d0cac06ef9"
if ! git merge-base --is-ancestor "$REQUIRED_WIFI_SCAN_FIX" HEAD 2>/dev/null; then
  echo "ERROR: source tree is missing required MTK Wi-Fi scan fix $REQUIRED_WIFI_SCAN_FIX" >&2
  exit 1
fi

# 临时解决Rust问题
sed -i 's/ci-llvm=true/ci-llvm=false/g' feeds/packages/lang/rust/Makefile

# add date in output file name
sed -i -e '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' \
       -e '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' include/image.mk

# set ubi to 122M
# sed -i 's/reg = <0x5c0000 0x7000000>;/reg = <0x5c0000 0x7a40000>;/' target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts

# ===============================
# OneCat custom defaults and 512M DTS injection.
# Do not remove original packages or change non-512M device logic.
# ===============================
BUILD_DEVICE="${BUILD_DEVICE:-}"

# Keep the device model and distribution identifiers intact; only set the custom brand fields.
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/90-onecat-defaults <<'EOF_ONECAT'
#!/bin/sh
uci set system.@system[0].hostname='OneCat'
uci set system.@system[0].description='OneCat定制版本'
uci commit system
exit 0
EOF_ONECAT
chmod +x files/etc/uci-defaults/90-onecat-defaults

# Add one explicit LuCI badge without rewriting page text or third-party copyright notices.
mkdir -p files/www/luci-static/custom files/etc/uci-defaults
cat > files/www/luci-static/custom/onecat-badge.js <<'EOF_BADGE_JS'
(function () {
  function addBadge() {
    if (document.getElementById('onecat-badge')) return;

    var badge = document.createElement('a');
    badge.id = 'onecat-badge';
    badge.textContent = 'OneCat定制版本';
    badge.href = 'https://github.com/asrtroh-netizen/immortalwrt-mt7981-cudy-tr3000';
    badge.target = '_blank';
    badge.rel = 'noopener noreferrer';
    badge.style.cssText = [
      'position:fixed','right:14px','bottom:14px','z-index:99999',
      'padding:6px 10px','border-radius:999px','font-size:12px',
      'line-height:1','text-decoration:none','background:rgba(0,0,0,.62)',
      'color:#fff','box-shadow:0 2px 10px rgba(0,0,0,.25)',
      'backdrop-filter:blur(6px)'
    ].join(';');
    document.body.appendChild(badge);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addBadge, { once: true });
  } else {
    addBadge();
  }
})();
EOF_BADGE_JS

cat > files/etc/uci-defaults/93-onecat-badge <<'EOF_BADGE_UCI'
#!/bin/sh
set -e
for f in /usr/share/ucode/luci/template/themes/*/header.ut /usr/lib/lua/luci/view/themes/*/header.htm; do
  [ -f "$f" ] || continue
  grep -q 'onecat-badge.js' "$f" && continue
  if grep -q '</body>' "$f"; then
    sed -i 's#</body>#<script src="/luci-static/custom/onecat-badge.js"></script></body>#' "$f"
  else
    printf '\n<script src="/luci-static/custom/onecat-badge.js"></script>\n' >> "$f"
  fi
done
exit 0
EOF_BADGE_UCI
chmod +x files/etc/uci-defaults/93-onecat-badge

# 512M DTS patch. Only run for BUILD_DEVICE=512M.
if [ "$BUILD_DEVICE" = "512M" ]; then
  echo "========== 512M DTS injection =========="
  TMP_DIR="/tmp/cudy-tr3000-512"
  rm -rf "$TMP_DIR"
  git clone --depth=1 https://github.com/zhuannn/cudy-tr3000-512 "$TMP_DIR"

  # Copy DTS if found.
  DTS_SRC="$(find "$TMP_DIR" -type f -name 'mt7981b-cudy-tr3000-512mb-v1.dts' | head -n 1)"
  if [ -n "$DTS_SRC" ]; then
    cp -f "$DTS_SRC" target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts
  else
    echo "ERROR: 512M DTS not found in zhuannn/cudy-tr3000-512"
    exit 1
  fi

  # Append device definition only if upstream tree does not already have it.
  if ! grep -R "cudy_tr3000-512mb-v1" -n target/linux/mediatek/image package 2>/dev/null | grep -q .; then
    MK_SRC="$(find "$TMP_DIR" -type f \( -name '*.mk' -o -name 'cudy-tr3000-512.mk' \) | head -n 1)"
    if [ -n "$MK_SRC" ]; then
      cat "$MK_SRC" >> target/linux/mediatek/image/filogic.mk
    else
      cat >> target/linux/mediatek/image/filogic.mk <<'EOF_512_DEV'

define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 512MB v1
  DEVICE_DTS := mt7981b-cudy-tr3000-512mb-v1
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 kmod-mt_wifi
  IMAGE_SIZE := 520000k
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
EOF_512_DEV
    fi
  fi
fi


# ==========================================
# 自定义部分
# ==========================================

# 删除 MTK 源码自带的易报错 5G 驱动（由 QModem 接管）
rm -rf package/mtk/applications/5g-modem

# 移除 openwrt feeds 自带的核心库
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,v2ray-plugin,xray-plugin,geoview,shadow-tls}
git clone https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages

# 移除 openwrt feeds 过时的luci版本
rm -rf feeds/luci/applications/luci-app-passwall
git clone https://github.com/Openwrt-Passwall/openwrt-passwall package/passwall-luci

# 创建存储二进制文件的目录
BIN_DIR="$GITHUB_WORKSPACE/openwrt/files/usr/bin"
mkdir -p "$BIN_DIR"

# -------- 下载并解压 xray-core ARM64 -------
echo "Downloading xray-core..."
XRAY_TAG=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep 'tag_name' | cut -d\" -f4)
curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_TAG}/Xray-linux-arm64-v8a.zip"
unzip -o xray.zip -d "$BIN_DIR"
chmod +x "$BIN_DIR/xray"
rm xray.zip

# -------- 下载并解压 sing-box ARM64 -------
echo "Downloading sing-box..."
SING_BOX_TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep 'tag_name' | cut -d\" -f4)
SING_BOX_VER=${SING_BOX_TAG#v}
curl -L -o sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_TAG}/sing-box-${SING_BOX_VER}-linux-arm64.tar.gz"
TMP_DIR=$(mktemp -d)
tar -xzf sing-box.tar.gz -C "$TMP_DIR"
mv "$TMP_DIR"/sing-box-${SING_BOX_VER}-linux-arm64/sing-box "$BIN_DIR"/sing-box
chmod +x "$BIN_DIR/sing-box"
rm -rf "$TMP_DIR"
rm sing-box.tar.gz

# PassWall 控制面板
echo "CONFIG_PACKAGE_luci-app-passwall=y" >> .config
echo "CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=y" >> .config

# 2. 手机 USB 共享网络驱动
# 安卓 USB 共享支持 (RNDIS)
echo "CONFIG_PACKAGE_kmod-usb-net-rndis=y" >> .config

# 苹果 iOS USB 共享支持 (Ipheth + Usbmuxd)
echo "CONFIG_PACKAGE_kmod-usb-net-ipheth=y" >> .config
echo "CONFIG_PACKAGE_usbmuxd=y" >> .config

# 基础 USB 网卡驱动及查看工具 (防止识别不到网卡)
echo "CONFIG_PACKAGE_kmod-usb-net=y" >> .config
echo "CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y" >> .config
echo "CONFIG_PACKAGE_usbutils=y" >> .config

# 解锁 MTD 分区写保护内核模块 (MTD-RW)
echo "CONFIG_PACKAGE_kmod-mtd-rw=y" >> .config

# FTP 服务器 (vsftpd 核心 + LuCI Web 界面 + 中文语言包)
echo "CONFIG_PACKAGE_vsftpd-alt=y" >> .config
echo "CONFIG_PACKAGE_luci-app-vsftpd=y" >> .config
echo "CONFIG_PACKAGE_luci-i18n-vsftpd-zh-cn=y" >> .config

# qmodem
echo "CONFIG_PACKAGE_qmodem=y" >> .config
echo "CONFIG_PACKAGE_luci-app-qmodem-next=y" >> .config