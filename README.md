# NetKit

一个用于管理网络服务、连接协议以及常用 VPS 系统工具的 Bash 管理脚本。当前核心为 Xray Core，后续会继续扩展其他核心。

## 项目定位

本项目主要用于个人使用，功能设计和后续完善方式也会优先按照我自己的使用习惯和需求来调整。

## 使用说明与免责声明

本项目是个人自用脚本，主要服务于我自己的 VPS 管理习惯和使用环境，并不保证适用于所有服务器、系统版本或网络环境。

如果您选择使用本项目，请务必先阅读脚本内容，确认自己理解相关操作可能带来的影响。部分功能会修改 SSH、防火墙、系统参数，或调用第三方重装 / 测试脚本，操作不当可能导致服务器无法连接、配置丢失或系统重装。

使用本项目所产生的任何问题、损失或风险均由使用者自行承担。若脚本不适合您的环境，请不要直接运行；如果运行后出现问题，也请自行排查和恢复。

## 安装与使用

```bash
apt update && apt install -y curl wget git ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/7o1ove/netkit/main/install.sh)
```

安装完成后，可以直接输入：

```bash
7o1ove
```

进入 NetKit 管理菜单。

## DMIT 网络恢复

### DD Debian 13 后无法联网

如果 DD Debian 13 后无法联网，可以通过 VNC 登录，确保 `noarp` 只写入一次后重启：

```bash
grep -qxF 'noarp' /etc/dhcpcd.conf || echo 'noarp' >> /etc/dhcpcd.conf
reboot
```

### 更换 XanMod 后无法通过 SSH 连接

部分 DMIT 实例在 Debian 原版内核与 XanMod 下会使用不同的主网卡名称。如果 `networking.service` 提示配置中的接口不存在，应通过 VNC 按以下流程恢复。所有网卡名均以实际查询结果为准，不要直接照抄其他机器的名称。

以 `root` 登录 VNC，加载 VirtIO 网卡模块并查看接口：

```bash
modprobe virtio_pci
modprobe virtio_net
ip -br link
```

单网卡 VPS 可用下面的命令取得 `lo` 之外的实际网卡名；如果存在多张网卡，请根据 `ip -br link` 的结果手动设置变量：

```bash
ACTUAL_IFACE=$(ls /sys/class/net | grep -vx 'lo' | head -n 1)
printf '实际网卡：%s\n' "$ACTUAL_IFACE"
```

确认变量正确后，临时启动网卡并通过 DHCP 获取地址：

```bash
ip link set "$ACTUAL_IFACE" up
dhcpcd -4 "$ACTUAL_IFACE"
ip -br addr
ip route
```

SSH 恢复后，先查询 ifupdown 当前写入的网卡名和配置文件位置：

```bash
ACTUAL_IFACE=$(ls /sys/class/net | grep -vx 'lo' | head -n 1)
grep -R -nE '^(auto|allow-hotplug|iface)' \
    /etc/network/interfaces /etc/network/interfaces.d/
```

如果非回环网卡配置位于 `/etc/network/interfaces`，可以执行以下命令自动读取旧名称，并直接替换为实际名称：

```bash
CONFIG_FILE=/etc/network/interfaces
CONFIG_IFACE=$(awk '$1 == "iface" && $2 != "lo" {print $2; exit}' "$CONFIG_FILE")

printf '配置中的网卡：%s\n' "$CONFIG_IFACE"
printf '系统实际网卡：%s\n' "$ACTUAL_IFACE"

if [[ -z "$ACTUAL_IFACE" || -z "$CONFIG_IFACE" ]]; then
    echo '未能识别网卡名称，请根据前面的查询结果手动检查，不要继续替换。'
else
    sed -i "s/${CONFIG_IFACE}/${ACTUAL_IFACE}/g" "$CONFIG_FILE"
    printf '%s\n' virtio_pci virtio_net > /etc/modules-load.d/dmit-virtio.conf
    ifquery "$ACTUAL_IFACE"
    systemctl reset-failed networking
fi
```

如果配置实际位于 `/etc/network/interfaces.d/`，请将 `CONFIG_FILE` 改为查询到的文件路径后再执行。最后确认配置：

```bash
cat "$CONFIG_FILE"
cat /etc/modules-load.d/dmit-virtio.conf
```

不要在仍运行原版内核、且配置已经换成新网卡名时执行 `systemctl restart networking`，否则当前 SSH 可能立即中断。配置确认无误后重启进入 XanMod：

```bash
reboot
```

重启后验证：

```bash
uname -r
systemctl is-active networking
ip -br addr
ip route
```

## 致谢

本项目在部分功能中会调用优秀的第三方脚本，在此感谢这些项目和作者的开源贡献：

- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)  
  用于安装和更新 Xray Core。

- [bin456789/reinstall](https://github.com/bin456789/reinstall)  
  用于 DD / 重装 Debian 系统。

- [NodeQuality](https://github.com/LloydAsp/NodeQuality)  
  用于 VPS 质量与网络测试。

- [XanMod 官方内核](https://xanmod.org/)
  用于在受支持的 Debian/Ubuntu x86_64 系统上安装包含 BBRv3 的 XanMod 内核。

这些脚本并非本项目原创，也不包含在本仓库源码中。本项目只是根据用户选择在线调用它们。使用前建议自行查看对应项目源码、说明和许可证，并确认脚本内容符合自己的使用需求。

再次感谢以上项目作者提供的便利工具。
