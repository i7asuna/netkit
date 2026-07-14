#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

SING_BOX_DIR="/etc/sing-box"
REQUESTED_VERSION="${1:-}"
INSTALL_ARGS=()

if [[ -n "$REQUESTED_VERSION" ]]; then
    if [[ ! "$REQUESTED_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "版本号格式无效：${REQUESTED_VERSION}"
        error "仅支持正式稳定版，例如 v1.13.12。"
        exit 1
    fi

    INSTALL_ARGS+=(--version "${REQUESTED_VERSION#v}")
fi

info "正在更新软件包列表..."

apt update

info "正在安装依赖..."

apt install -y \
    curl \
    ca-certificates

if [[ -n "$REQUESTED_VERSION" ]]; then
    info "正在安装 Sing-box ${REQUESTED_VERSION}..."
else
    info "正在安装 Sing-box 最新正式稳定版..."
fi

# The official installer selects the latest stable release unless --beta is used.
bash <(
    curl -fsSL -L \
    https://sing-box.app/install.sh
) "${INSTALL_ARGS[@]}"

info "正在检查 Sing-box..."

if command -v sing-box >/dev/null 2>&1; then
    SING_BOX_BIN="$(command -v sing-box)"
elif [[ -x /usr/local/bin/sing-box ]]; then
    SING_BOX_BIN="/usr/local/bin/sing-box"
elif [[ -x /usr/bin/sing-box ]]; then
    SING_BOX_BIN="/usr/bin/sing-box"
else
    error "Sing-box 安装失败。"
    exit 1
fi

SING_BOX_VERSION="$("$SING_BOX_BIN" version | awk 'NR == 1 { print $3; exit }')"

if [[ ! "$SING_BOX_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "检测到非正式稳定版本：${SING_BOX_VERSION:-未知版本}"
    error "已拒绝继续配置，请仅安装 Sing-box 正式稳定版。"
    exit 1
fi

info "正在准备目录..."

mkdir -p \
    "${SING_BOX_DIR}" \
    "${SING_BOX_DIR}/protocols" \
    "${SING_BOX_DIR}/client"

info "正在启用 Sing-box 服务..."

systemctl enable sing-box

# Stop the service until a valid protocol configuration is generated.
systemctl stop sing-box 2>/dev/null || true

banner "Sing-box 安装完成" "$GREEN"

value "$("$SING_BOX_BIN" version | head -n1)"

echo
path_kv "程序文件        :" "$SING_BOX_BIN"
path_kv "配置目录        :" "${SING_BOX_DIR}"
path_kv "协议配置        :" "${SING_BOX_DIR}/protocols"
path_kv "连接信息        :" "${SING_BOX_DIR}/client"

echo
divider "$GREEN"
success "正式稳定版安装完成。"
success "Sing-box 服务已设置为开机启动。"
success "服务会在协议配置完成后启动。"
divider "$GREEN"
