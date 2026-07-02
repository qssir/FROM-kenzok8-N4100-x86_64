#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-25.12-SNAPSHOT}"
TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/x86/64/immortalwrt-imagebuilder-25.12-SNAPSHOT-x86-64.Linux-x86_64.tar.zst}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
PREFLIGHT="${PREFLIGHT:-1}"
# 👑 默认直接对齐 2GB 豪华固件分区
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-2048}"
INSTALL_DAEDE="${INSTALL_DAEDE:-1}"
DAEDE_REPO="${DAEDE_REPO:-kenzok8/openwrt-daede}"
DAEDE_RELEASE_TAG="${DAEDE_RELEASE_TAG:-latest}"
DAEDE_ARCH="${DAEDE_ARCH:-x86_64}"
DAEDE_APK_URL="${DAEDE_APK_URL:-}"

# 📦 满血全家桶核心软件包对齐 (已彻底剥离软件源缺失的 wrtbwmon 与 shadowsocks 旧组件，确保核心 Passwall+Xray/DAED/Docker/FUSE/储存下载完美通过)
EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn luci-i18n-package-manager-zh-cn luci-app-daede kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano kmod-fuse fuse-utils kmod-fs-ext4 kmod-fs-vfat kmod-fs-ntfs3 luci-app-dockerman docker-compose luci-app-alist luci-app-samba4 luci-app-minidlna luci-app-qbittorrent luci-app-transmission luci-app-aria2 luci-app-passwall xray-core luci-app-zerotier luci-app-n2n luci-app-softethervpn luci-app-ipsec-vpnd luci-app-syncdial luci-app-eqos luci-app-ttyd luci-app-diskman luci-app-filebrowser luci-theme-argon}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"

resolve_daede_apk_url() {
  if [ -n "$DAEDE_APK_URL" ]; then
    printf '%s\n' "$DAEDE_APK_URL"
    return
  fi

  local release_api
  if [ "$DAEDE_RELEASE_TAG" = "latest" ]; then
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/latest"
  else
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/tags/$DAEDE_RELEASE_TAG"
  fi

  python3 - "$release_api" "$DAEDE_ARCH" <<'PY'
import json
import os
import sys
import urllib.request

release_api, arch = sys.argv[1:3]
request = urllib.request.Request(
    release_api,
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "kenzok8-imagebuilder",
    },
)
token = os.environ.get("GITHUB_TOKEN")
if token:
    request.add_header("Authorization", f"Bearer {token}")

with urllib.request.urlopen(request, timeout=30) as response:
    release = json.load(response)

suffix = f"-{arch}.apk"
matches = [
    asset.get("browser_download_url") or asset.get("url")
    for asset in release.get("assets", [])
    if asset.get("name", "").startswith("luci-app-daede-")
    and asset.get("name", "").endswith(suffix)
]

if not matches:
    tag = release.get("tag_name", release_api)
    raise SystemExit(f"luci-app-daede APK for {arch} not found in {tag}")

print(matches[0])
PY
}

install_daede_apk() {
  case "$INSTALL_DAEDE" in
    1|true|yes) ;;
    *)
      echo "Skipping luci-app-daede release APK download."
      return
      ;;
  esac

  local packages_dir="$WORK_DIR/imagebuilder/packages"
  local daede_url
  daede_url="$(resolve_daede_apk_url)"
  mkdir -p "$packages_dir"

  local fname="${daede_url##*/}"
  fname="${fname%-${DAEDE_ARCH}.apk}.apk"

  echo "Downloading luci-app-daede APK: $daede_url -> $fname"
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
    -o "$packages_dir/$fname" "$daede_url"
}

if [ ! -s "$IB_ARCHIVE" ]; then
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
    -o "$IB_ARCHIVE" "$IMAGEBUILDER_URL"
fi

rm -rf "$WORK_DIR/imagebuilder"
mkdir -p "$WORK_DIR/imagebuilder"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$WORK_DIR/imagebuilder" --strip-components=1

# =====================================================================
# ⚡ 编译前置动态注入：4K 媒体网络栈与存储底层高速优化补丁
# =====================================================================
mkdir -p files/etc/sysctl.d files/etc/init.d

# 注入内核 BBR 与高吞吐量缓冲区缓存隔离参数
cat << 'EOF' > files/etc/sysctl.d/99-4k-media-optimize.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=33554432
net.core.wmem_default=33554432
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.vfs_cache_pressure=50
EOF

# 自动生成 1T SSD 块设备 16MB 强行预读加速脚本
cat << 'EOF' > files/etc/init.d/media_io_init
#!/bin/sh /etc/rc.common
START=99

start() {
    for dev in sda sdb nvme0n1; do
        if [ -b "/dev/$dev" ]; then
            echo "none" > /sys/block/$dev/queue/scheduler 2>/dev/null || true
            blockdev --setra 16384 /dev/$dev 2>/dev/null || true
        fi
    done
    modprobe tcp_bbr 2>/dev/null || true
}
EOF
chmod +x files/etc/init.d/media_io_init

# 将配置注入到构建工位
cp -a files "$WORK_DIR/imagebuilder/files"
install_daede_apk

cd "$WORK_DIR/imagebuilder"

echo "Version: $VERSION"
echo "Target: $TARGET"
echo "Profile: $PROFILE"
echo "Rootfs part size: ${ROOTFS_PARTSIZE}MB"
echo "Extra packages: $EXTRA_PACKAGES"
echo "Install daede APK: $INSTALL_DAEDE"
echo "Daede release: $DAEDE_REPO@$DAEDE_RELEASE_TAG ($DAEDE_ARCH)"
mkdir -p "$OUT_DIR"
echo "extra_packages=$EXTRA_PACKAGES" > "$OUT_DIR/.extra_packages"

diagnose_failure() {
  cat >&2 <<'EOF'

ImageBuilder failed.
EOF
}

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then
  echo "Running package manifest preflight..."
  if ! make manifest PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES"; then
    diagnose_failure
    exit 1
  fi
fi

sed -i \
  -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
  -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
  -e 's/^CONFIG_VDI_IMAGES=y/# CONFIG_VDI_IMAGES is not set/' \
  -e 's/^CONFIG_VHDX_IMAGES=y/# CONFIG_VHDX_IMAGES is not set/' \
  -e 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' \
  -e 's/^CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' \
  .config

if ! make image \
    PROFILE="$PROFILE" \
    PACKAGES="$EXTRA_PACKAGES" \
    FILES=files \
    BIN_DIR="$OUT_DIR" \
    EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"; then
  diagnose_failure
  exit 1
fi

cd "$OUT_DIR"
for f in *-squashfs-combined-efi.img.gz;  do [ -f "$f" ] && mv "$f" daede-squashfs-efi.img.gz;  done
for f in *-squashfs-combined-efi.qcow2; do [ -f "$f" ] && mv "$f" daede-squashfs-efi.qcow2; done
for f in *-squashfs-combined-efi.vmdk;  do [ -f "$f" ] && mv "$f" daede-squashfs-efi.vmdk;  done
for f in *-kernel.bin;                do [ -f "$f" ] && mv "$f" daede-kernel.bin;            done
for f in *-rootfs.tar.gz;             do [ -f "$f" ] && mv "$f" daede-rootfs.tar.gz;         done
for f in *.manifest;                  do [ -f "$f" ] && mv "$f" daede.manifest;              done
for f in *.bom.cdx.json;              do [ -f "$f" ] && mv "$f" daede.bom.cdx.json;          done
for f in *.img.gz *.qcow2 *.vmdk *.bin *.tar.gz *.manifest *.bom.cdx.json; do
  [ -f "$f" ] || continue
  sha256sum "$f"
done > sha256sums

BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"
cat > BUILD-MANIFEST.txt <<BODYEOF
## daede 固件 · ${EXTRA_IMAGE_NAME}
根分区大小：${ROOTFS_PARTSIZE} MB
构建日期：${BUILD_DATE}
BODYEOF
ls -la "$OUT_DIR"
