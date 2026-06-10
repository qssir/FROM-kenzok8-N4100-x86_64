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
DAEDE_REPO="${DAEDE_REPO:-kenzok8/openwrt-daede}"
DAEDE_RELEASE_TAG="${DAEDE_RELEASE_TAG:-latest}"
DAEDE_ARCH="${DAEDE_ARCH:-x86_64}"
DAEDE_PACKAGES="${DAEDE_PACKAGES:-dae daed luci-app-daede}"
DAEDE_APK_URL="${DAEDE_APK_URL:-}"

EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn luci-i18n-package-manager-zh-cn luci-app-daede kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"

resolve_daede_asset_urls() {
  local release_api
  if [ "$DAEDE_RELEASE_TAG" = "latest" ]; then
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/latest"
  else
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/tags/$DAEDE_RELEASE_TAG"
  fi

  python3 - "$release_api" "$DAEDE_ARCH" $DAEDE_PACKAGES <<'PY'
import json
import os
import sys
import urllib.request

release_api, arch = sys.argv[1:3]
packages = sys.argv[3:]
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
assets = release.get("assets", [])
tag = release.get("tag_name", release_api)

# Match each package by its own "<name>-" prefix so "dae-" never grabs "daed-".
urls = []
for pkg in packages:
    matches = [
        asset.get("browser_download_url") or asset.get("url")
        for asset in assets
        if asset.get("name", "").startswith(f"{pkg}-")
        and asset.get("name", "").endswith(suffix)
    ]
    if not matches:
        raise SystemExit(f"{pkg} APK for {arch} not found in {tag}")
    urls.append(matches[0])

print("\n".join(urls))
PY
}

install_daede_packages() {
  case "$INSTALL_DAEDE" in
    1|true|yes) ;;
    *)
      echo "Skipping daede release APK download."
      return
      ;;
  esac

  local packages_dir="$WORK_DIR/imagebuilder/packages"
  mkdir -p "$packages_dir"

  # Legacy escape hatch: a single explicit APK URL. In this mode only that
  # file is fetched, so dae/daed are still resolved from the ImmortalWrt feed.
  if [ -n "$DAEDE_APK_URL" ]; then
    echo "DAEDE_APK_URL override set; downloading only this APK."
    echo "Note: dae/daed come from the ImmortalWrt feed in this mode."
    curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
      -o "$packages_dir/${DAEDE_APK_URL##*/}" "$DAEDE_APK_URL"
    return
  fi

  local urls
  urls="$(resolve_daede_asset_urls)"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    echo "Downloading daede APK: $url"
    curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
      -o "$packages_dir/${url##*/}" "$url"
  done <<< "$urls"
}

if [ ! -s "$IB_ARCHIVE" ]; then
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
    -o "$IB_ARCHIVE" "$IMAGEBUILDER_URL"
fi

rm -rf "$WORK_DIR/imagebuilder"
mkdir -p "$WORK_DIR/imagebuilder"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$WORK_DIR/imagebuilder" --strip-components=1

cp -a files "$WORK_DIR/imagebuilder/files"
install_daede_packages

cd "$WORK_DIR/imagebuilder"

echo "Version: $VERSION"
echo "Target: $TARGET"
echo "Profile: $PROFILE"
echo "Rootfs part size: ${ROOTFS_PARTSIZE}MB"
echo "Extra packages: $EXTRA_PACKAGES"
echo "Install daede APK: $INSTALL_DAEDE"
echo "Daede release: $DAEDE_REPO@$DAEDE_RELEASE_TAG ($DAEDE_ARCH)"
echo "Daede packages from release: $DAEDE_PACKAGES"
mkdir -p "$OUT_DIR"
echo "extra_packages=$EXTRA_PACKAGES" > "$OUT_DIR/.extra_packages"

diagnose_failure() {
  cat >&2 <<'EOF'

ImageBuilder failed.

Common causes for this daede image:
- The selected ImmortalWrt snapshot ImageBuilder and package feeds are out of sync.
  Example: base packages require a newer libubox/libblobmsg-json than the public feed provides.
- One of the dae/daed eBPF kmod dependencies
  (kmod-sched-bpf / kmod-veth / kmod-xdp-sockets-diag)
  is missing from the selected target's kmod feed for the current kernel version.
  These kmods still come from the ImmortalWrt feed.
- A dae/daed/luci-app-daede release APK was not copied into the local ImageBuilder
  packages directory, or its architecture does not match the selected target.
- dae/daed/luci-app-daede now come from the openwrt-daede release (date-based
  versions like 2026.x), which outrank the feed's 1.x builds so apk prefers them.
  If the feed ever ships a higher version, pin the local one explicitly in PACKAGES.

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
- Override DAEDE_RELEASE_TAG, DAEDE_ARCH, or DAEDE_APK_URL if you need a specific
  luci-app-daede release asset.
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
