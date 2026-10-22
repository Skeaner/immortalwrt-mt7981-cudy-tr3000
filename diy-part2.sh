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

# 7. 修改默认 LAN IP 为 192.168.10.1
sed -i 's/192\.168\.6\.1/192.168.69.2/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# 修复QMODEM问题
set -euo pipefail

cd "$GITHUB_WORKSPACE/openwrt"

# 1) 自动定位 MTK 自带的 Fibocom QMI 驱动目录
PKG_DIR=""
for d in \
  "$PWD/package/mtk/applications/5g-modem/fibocom_QMI_WWAN" \
  "$PWD/feeds/mtk/applications/5g-modem/fibocom_QMI_WWAN" \
  "$PWD/package/mtk/5g-modem/fibocom_QMI_WWAN" \
  "$PWD/feeds/mtk/5g-modem/fibocom_QMI_WWAN"
do
  if [ -f "$d/qmi_wwan_f.c" ]; then
    PKG_DIR="$d"
    break
  fi
done

if [ -n "$PKG_DIR" ]; then
  echo "Patching $PKG_DIR for Linux 6.6 compatibility..."

  mkdir -p "$PKG_DIR/patches"

  cat > "$PKG_DIR/patches/0001-linux-6.6-u64-stats-compat.patch" <<'PATCH'
--- a/qmi_wwan_f.c
+++ b/qmi_wwan_f.c
@@
 #include <linux/if_arp.h>
 #include <linux/if_ether.h>
+#include <linux/u64_stats_sync.h>
 #include <linux/ip.h>
@@
-            start = u64_stats_fetch_begin_irq(&stats64->syncp);
+#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
+            start = u64_stats_fetch_begin(&stats64->syncp);
+#else
+            start = u64_stats_fetch_begin_irq(&stats64->syncp);
+#endif
@@
-        } while (u64_stats_fetch_retry_irq(&stats64->syncp, start));
+#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
+        } while (u64_stats_fetch_retry(&stats64->syncp, start));
+#else
+        } while (u64_stats_fetch_retry_irq(&stats64->syncp, start));
+#endif
PATCH

  patch -p1 -d "$PKG_DIR" < "$PKG_DIR/patches/0001-linux-6.6-u64-stats-compat.patch"
  echo "Patch applied successfully"
else
  echo "fibocom_QMI_WWAN not found, skip patch"
fi

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

# 2. 更新 Go 语言包到 1.27.x
rm -rf feeds/packages/lang/golang

git clone --depth 1 --branch 27.x \
  https://github.com/sbwml/packages_lang_golang \
  feeds/packages/lang/golang

# 删除 MTK 源码自带的易报错 5G 驱动（由 QModem 接管）
# rm -rf package/mtk/applications/5g-modem

# 替换 Passwall 相关依赖包
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}

rm -rf package/passwall-packages
git clone --depth 1 \
  https://github.com/Openwrt-Passwall/openwrt-passwall-packages \
  package/passwall-packages

rm -rf feeds/luci/applications/luci-app-passwall
rm -rf package/passwall-luci

git clone --depth 1 \
  https://github.com/Openwrt-Passwall/openwrt-passwall \
  package/passwall-luci

