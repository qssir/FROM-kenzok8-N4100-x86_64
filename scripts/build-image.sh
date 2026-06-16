#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-25.12-SNAPSHOT}"
TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/x86/64/immortalwrt-imagebuilder-25.12-SNAPSHOT-x86-64.Linux-x86_64.tar.zst}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
PREFLIGHT="${PREFLIGHT:-1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
INSTALL_DAEDE="${INSTALL_DAEDE:-1}"
DAEDE_ARCH="${DAEDE_ARCH:-x86_64}"

EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn luci-i18n-package-manager-zh-cn luci-app-daede kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"

setup_daede_feed() {
  case "$INSTALL_DAEDE" in
    1|true|yes) ;;
    *)
      echo "Skipping luci-app-daede (INSTALL_DAEDE != true)."
      return
      ;;
  esac

  # daede APK feed — same prebuilt .apk as the GitHub release. Adding it to
  # the ImageBuilder repositories lets `make manifest` and `make image` resolve
  # luci-app-daede normally, without touching the local packages/ directory.
  local sdk target_arch feed_url
  sdk="$(echo "$IMAGEBUILDER_URL" | grep -oE '[0-9]+\.[0-9]+(-SNAPSHOT)?' | head -1)"
  [ -n "$sdk" ] || sdk="25.12"
  target_arch="${DAEDE_ARCH:-x86_64}"
  feed_url="https://down.dllkids.xyz/openwrt-feed/${sdk}/${target_arch}"
  echo "daede feed: $feed_url"
  grep -qxF "$feed_url" repositories 2>/dev/null || printf '%s\n' "$feed_url" >> repositories
}

if [ ! -s "$IB_ARCHIVE" ]; then
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
    -o "$IB_ARCHIVE" "$IMAGEBUILDER_URL"
fi

rm -rf "$WORK_DIR/imagebuilder"
mkdir -p "$WORK_DIR/imagebuilder"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$WORK_DIR/imagebuilder" --strip-components=1

cp -a files "$WORK_DIR/imagebuilder/files"
setup_daede_feed

cd "$WORK_DIR/imagebuilder"

echo "Version: $VERSION"
echo "Target: $TARGET"
echo "Profile: $PROFILE"
echo "Rootfs part size: ${ROOTFS_PARTSIZE}MB"
echo "Extra packages: $EXTRA_PACKAGES"
echo "Install daede APK: $INSTALL_DAEDE"
mkdir -p "$OUT_DIR"
echo "extra_packages=$EXTRA_PACKAGES" > "$OUT_DIR/.extra_packages"

diagnose_failure() {
  cat >&2 <<'EOF'

ImageBuilder failed.

Common causes for this daede image:
- The luci-app-daede feed was not added to ImageBuilder repositories,
  or the feed is unreachable / missing packages for this arch.
- The selected ImmortalWrt snapshot ImageBuilder and package feeds are out of sync
  (example: base packages require a newer libubox/libblobmsg-json than the feed provides).
- The kmod-* eBPF dependencies are missing from the target's kmod feed
  for the current kernel version.

About BTF (no longer a blocker on 25.12):
- ImmortalWrt 25.12 kernels enable CONFIG_DEBUG_INFO_BTF by default. dae/daed reads BTF
  directly from /sys/kernel/btf/vmlinux at runtime and does NOT require a separate
  vmlinux-btf package. Do not add vmlinux-btf to EXTRA_PACKAGES — it is not published
  in the feed and ImageBuilder cannot build it.
- If you ever target an older OpenWrt release whose kernel lacks built-in BTF, build
  vmlinux-btf via a full SDK build first (ImageBuilder cannot compile packages).

Next choices:
- Retry later with the same 25.12-SNAPSHOT URL after ImmortalWrt feeds finish syncing.
- Use a release/rc ImageBuilder URL and rebuild daede/dae/daed APKs against that release/rc.
- Override DAEDE_ARCH if the target architecture differs from the default (x86_64).
- Verify kmod-* packages exist for the target+kernel combo via:
    make manifest PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES"
EOF
}

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then
  echo "Running package manifest preflight..."
  if ! make manifest PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES"; then
    diagnose_failure
    exit 1
  fi
fi

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

find "$OUT_DIR" -maxdepth 1 -type f -print
