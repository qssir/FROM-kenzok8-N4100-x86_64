# imagebuilder

[中文](#中文) | [英文](#english)

## 中文

构建一个 ImmortalWrt x86/64 测试固件，默认包含
[`luci-app-daede`](https://github.com/kenzok8/openwrt-daede) 以及运行
`dae` / `daed` 所需的基础依赖。

### 默认固件

- 版本：ImmortalWrt `25.12-SNAPSHOT`
- 目标：`x86/64`
- Profile：`generic`
- Rootfs 分区：`2048` MB (2GB 豪华分区，余下空间留给开机后 Diskman 一键扩容)
- ImageBuilder URL：
  `https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/x86/64/immortalwrt-imagebuilder-25.12-SNAPSHOT-x86-64.Linux-x86_64.tar.zst`
- 快捷链接：
  [`kenzok8/openwrt-daede`](https://github.com/kenzok8/openwrt-daede)

### 默认安装包

工作流默认从
[`kenzok8/openwrt-daede`](https://github.com/kenzok8/openwrt-daede) 的
GitHub Release 下载匹配架构的 `luci-app-daede-*-x86_64.apk`，放入
ImageBuilder 本地包源。

本固件集成了**满血全家桶核心软件包**（坚决不含 Python 编译组件，彻底断绝编译死循环），安装以下软件包：

```text
# 核心底座与 eBPF 依赖
luci
luci-i18n-base-zh-cn
luci-i18n-package-manager-zh-cn
luci-app-daede
kmod-sched-core
kmod-sched-bpf
kmod-veth
kmod-xdp-sockets-diag
curl
nano

# FUSE 挂载与存储驱动 (彻底解决 AList 无法挂载硬伤)
kmod-fuse
fuse-utils
kmod-fs-ext4
kmod-fs-vfat
kmod-fs-ntfs3

# Docker 运行环境集成
luci-app-dockerman
docker-compose

# 🎬 影音聚合与存储下载全家桶
luci-app-alist
luci-app-samba4
luci-app-minidlna
luci-app-qbittorrent
luci-app-transmission
luci-app-aria2

# 🌐 传统经典代理服务
luci-app-passwall
luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client
luci-app-passwall_INCLUDE_Xray

# 🛡️ VPN 与异地组网菜单
luci-app-zerotier
luci-app-n2n
luci-app-softethervpn
luci-app-ipsec-vpnd

# ⚡ 网络菜单增强包 (多拨与控流)
luci-app-syncdial
luci-app-eqos
luci-app-wrtbwmon

# 🛠️ 系统与维护增强
luci-app-ttyd
luci-app-diskman
luci-app-filebrowser

# 🎨 界面优化
luci-theme-argon
