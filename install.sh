#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/7o1ove/xray-manager.git"
INSTALL_DIR="/root/xray-manager"

echo "=================================="
echo "Installing Xray Manager..."
echo "=================================="

# 1. 如果目录存在就更新，不存在就clone
if [ -d "$INSTALL_DIR" ]; then
    echo "[+] Directory exists, updating..."
    cd "$INSTALL_DIR"
    git pull
else
    echo "[+] Cloning repo..."
    git clone "$REPO" "$INSTALL_DIR"
fi

# 2. 进入目录
cd "$INSTALL_DIR"

# 3. 给执行权限
chmod +x *.sh 2>/dev/null || true
chmod +x core/*.sh 2>/dev/null || true
chmod +x system/*.sh 2>/dev/null || true

# 4. 启动主程序
echo ""
echo "=================================="
echo "Installation completed!"
echo "Starting Xray Manager..."
echo "=================================="
echo ""

bash manager.sh