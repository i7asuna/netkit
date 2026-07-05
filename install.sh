#!/usr/bin/env bash

set -e

REPO="https://github.com/7o1ove/Xray-manager.git"
INSTALL_DIR="/opt/Xray-manager"

echo "=================================="
echo "   Xray-manager Installer"
echo "=================================="

# 1. 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Please run as root"
    exit 1
fi

# 2. 更新系统 & 安装依赖
echo "==> Installing dependencies..."
apt update -y
apt install -y git curl

# 3. 清理旧目录
if [ -d "$INSTALL_DIR" ]; then
    echo "==> Removing old installation..."
    rm -rf "$INSTALL_DIR"
fi

# 4. clone 项目
echo "==> Cloning repository..."
git clone "$REPO" "$INSTALL_DIR"

cd "$INSTALL_DIR"

# 5. 授权脚本执行权限
chmod +x *.sh
chmod +x core/*.sh system/*.sh

# 6. 启动主程序
echo "=================================="
echo "Installation completed!"
echo "Starting Xray-manager..."
echo "=================================="

bash xray-manager.sh