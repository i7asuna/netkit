# NetKit

一个用于管理 Mihomo、连接协议以及常用 VPS 系统工具的 Bash 管理脚本。

## 项目定位

本项目主要用于个人使用，功能设计和后续完善方式也会优先按照我自己的使用习惯和需求来调整。

## 使用说明与免责声明

本项目是个人自用脚本，主要服务于我自己的 VPS 管理习惯和使用环境，并不保证适用于所有服务器、系统版本或网络环境。

如果您选择使用本项目，请务必先阅读脚本内容，确认自己理解相关操作可能带来的影响。部分功能会修改 SSH、防火墙、系统参数，或调用第三方重装 / 测试脚本，操作不当可能导致服务器无法连接、配置丢失或系统重装。

使用本项目所产生的任何问题、损失或风险均由使用者自行承担。若脚本不适合您的环境，请不要直接运行；如果运行后出现问题，也请自行排查和恢复。

## 安装与使用

```bash
apt update && apt install -y curl wget git ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/i7asuna/netkit/main/install.sh)
```

安装完成后，可以直接输入：

```bash
asuna
```

进入 NetKit 管理菜单。

## DMIT 网络恢复

### DD Debian 13 后无法通过 SSH 连接

如果 DD Debian 13 后无法联网，可以通过 VNC 登录系统后执行：

```bash
grep -qxF 'noarp' /etc/dhcpcd.conf || echo 'noarp' >> /etc/dhcpcd.conf
reboot
```

## 致谢

本项目在部分功能中会调用优秀的第三方脚本，在此感谢这些项目和作者的开源贡献：

- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 提供 Mihomo 内核与 Listener 服务端能力。

- [bin456789/reinstall](https://github.com/bin456789/reinstall) 用于 DD / 重装 Debian 系统。

- [xykt/IPQuality](https://github.com/xykt/IPQuality) 用于 IP 质量检测。

- [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality) 用于 TCP 质量检测。

- [nxtrace/NTrace-core](https://github.com/nxtrace/NTrace-core) 用于大小包路由追踪。

这些脚本并非本项目原创，也不包含在本仓库源码中。本项目只是根据用户选择在线调用它们。使用前建议自行查看对应项目源码、说明和许可证，并确认脚本内容符合自己的使用需求。

再次感谢以上项目作者提供的便利工具。
