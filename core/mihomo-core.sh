#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_SERVICE_FILE="/etc/systemd/system/mihomo.service"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
REQUESTED_VERSION="${1:-}"

if [[ -n "$REQUESTED_VERSION" && ! "$REQUESTED_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "版本号格式无效：${REQUESTED_VERSION}"
    error "仅支持正式稳定版版本号。"
    exit 1
fi

info "正在安装 Mihomo 环境依赖..."
apt update
apt install -y curl ca-certificates gzip coreutils

if [[ -n "$REQUESTED_VERSION" ]]; then
    VERSION="$REQUESTED_VERSION"
else
    info "正在获取 Mihomo 最新正式稳定版..."
    RELEASE_JSON=$(curl -fsSL -L \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)
    VERSION=$(sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' <<< "$RELEASE_JSON" | head -n1)

    if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "无法获取 Mihomo 最新正式稳定版版本号。"
        exit 1
    fi
fi

case "$(uname -m)" in
    x86_64|amd64)
        ASSET="mihomo-linux-amd64-compatible-${VERSION}.gz"
        ;;
    aarch64|arm64)
        ASSET="mihomo-linux-arm64-${VERSION}.gz"
        ;;
    armv7l|armv7)
        ASSET="mihomo-linux-armv7-${VERSION}.gz"
        ;;
    i386|i486|i586|i686)
        ASSET="mihomo-linux-386-${VERSION}.gz"
        ;;
    *)
        error "暂不支持当前 CPU 架构：$(uname -m)"
        exit 1
        ;;
esac

DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}/${ASSET}"
ARCHIVE=$(mktemp /tmp/mihomo.XXXXXX.gz)
EXTRACTED=$(mktemp /tmp/mihomo.XXXXXX)

cleanup(){
    rm -f "$ARCHIVE" "$EXTRACTED"
}
trap cleanup EXIT

info "正在下载 Mihomo ${VERSION}..."
curl -fL --retry 3 --retry-delay 2 -o "$ARCHIVE" "$DOWNLOAD_URL"

if ! gzip -t "$ARCHIVE"; then
    error "Mihomo 下载文件校验失败。"
    exit 1
fi

gzip -dc "$ARCHIVE" > "$EXTRACTED"
chmod 0755 "$EXTRACTED"

if ! "$EXTRACTED" -v >/dev/null 2>&1; then
    error "下载的 Mihomo 程序无法运行，请检查系统架构兼容性。"
    exit 1
fi

install -m 0755 "$EXTRACTED" "$MIHOMO_BIN"

INSTALLED_VERSION=$("$MIHOMO_BIN" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
if [[ "$INSTALLED_VERSION" != "$VERSION" ]]; then
    error "Mihomo 版本校验失败：期望 ${VERSION}，实际 ${INSTALLED_VERSION:-未知}。"
    exit 1
fi

info "正在准备 Mihomo 目录和服务..."
mkdir -p \
    "$MIHOMO_DIR" \
    "${MIHOMO_DIR}/protocols" \
    "${MIHOMO_DIR}/client"

cat > "$MIHOMO_SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=${MIHOMO_BIN} -d ${MIHOMO_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mihomo

HAS_PROTOCOL=false
for file in "${MIHOMO_DIR}/protocols"/*.yaml; do
    if [[ -f "$file" ]]; then
        HAS_PROTOCOL=true
        break
    fi
done

if $HAS_PROTOCOL; then
    bash "$BUILD_CONFIG_SCRIPT"
    systemctl restart mihomo
else
    systemctl stop mihomo 2>/dev/null || true
fi

banner "Mihomo 安装完成" "$GREEN"
value "$("$MIHOMO_BIN" -v | head -n1)"

echo
path_kv "程序文件        :" "$MIHOMO_BIN"
path_kv "配置目录        :" "$MIHOMO_DIR"
path_kv "协议配置        :" "${MIHOMO_DIR}/protocols"
path_kv "连接信息        :" "${MIHOMO_DIR}/client"

echo
divider "$GREEN"
success "Mihomo ${VERSION} 安装完成。"
success "Mihomo 服务已设置为开机启动。"
if $HAS_PROTOCOL; then
    success "现有协议配置已重建，Mihomo 服务已重启。"
else
    success "服务会在协议配置完成后启动。"
fi
divider "$GREEN"
