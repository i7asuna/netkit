#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/xray-manager"

# shellcheck source=/root/xray-manager/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XRAY_DIR="/usr/local/etc/xray"

PROTOCOL_CONFIG="${XRAY_DIR}/protocols/vless.json"
CLIENT_FILE="${XRAY_DIR}/client/vless.txt"
MIHOMO_FILE="${XRAY_DIR}/client/vless-mihomo.yaml"

FLOW="xtls-rprx-vision"
FINGERPRINT="chrome"

ensure_dependencies(){
    local missing=()
    local package

    for package in curl openssl coreutils iproute2; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            missing+=("$package")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        info "正在安装 VLESS Reality 环境依赖..."
        apt update
        apt install -y "${missing[@]}"
    fi
}

ensure_dependencies

info "正在检查 Xray..."

if command -v xray >/dev/null 2>&1; then
    XRAY_BIN=$(command -v xray)
elif [[ -x /usr/local/bin/xray ]]; then
    XRAY_BIN="/usr/local/bin/xray"
elif [[ -x /usr/bin/xray ]]; then
    XRAY_BIN="/usr/bin/xray"
else
    error "请先安装 Xray Core。"
    exit 1
fi

mkdir -p "${XRAY_DIR}"
mkdir -p "${XRAY_DIR}/protocols"
mkdir -p "${XRAY_DIR}/client"

SERVER_IP=$(
    curl -4 -fsSL https://api.ipify.org ||
    curl -6 -fsSL https://api64.ipify.org ||
    echo "Unknown"
)

read -r -p "$(prompt_text "端口（留空随机）: ")" PORT

if [[ -z "$PORT" ]]; then
    while :; do
        PORT=$(shuf -i 30000-60000 -n1)
        ss -ltnH | awk '{print $4}' | grep -q ":${PORT}$" || break
    done
fi

read -r -p "$(prompt_text "Reality SNI（默认 icloud.com）: ")" SNI

SNI=${SNI:-icloud.com}
SNI=${SNI#https://}
SNI=${SNI#http://}
SNI=${SNI%/}

info "正在生成 UUID..."

UUID=$("$XRAY_BIN" uuid | xargs)

info "正在生成 Reality 密钥..."

KEY_PAIR=$("$XRAY_BIN" x25519)

PRIVATE_KEY=$(echo "$KEY_PAIR" | \
grep "^PrivateKey:" | \
cut -d':' -f2- | \
xargs)

PUBLIC_KEY=$(echo "$KEY_PAIR" | \
grep "^Password (PublicKey):" | \
cut -d':' -f2- | \
xargs)

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "Reality 密钥生成失败。"
    exit 1
fi

info "正在生成 Short ID..."

SHORT_ID=$(openssl rand -hex 8)

info "正在写入 VLESS Reality 协议配置..."

cat > "$PROTOCOL_CONFIG" <<EOF
{
  "listen": "::",
  "port": $PORT,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$UUID",
        "flow": "$FLOW"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "sockopt": {
      "tcpFastOpen": true,
      "tcpNoDelay": true
    },
    "realitySettings": {
      "show": false,
      "dest": "${SNI}:443",
      "xver": 0,
      "serverNames": [
        "${SNI}"
      ],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": [
        "$SHORT_ID"
      ]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
    ],
    "routeOnly": true
  }
}
EOF

info "正在构建 Xray 配置..."
if ! bash /root/xray-manager/config/build_config.sh; then
    exit 1
fi

info "正在更新防火墙..."

if command -v ufw >/dev/null 2>&1; then
    ufw status | grep -q "${PORT}/tcp" || \
    ufw allow "${PORT}/tcp" comment "Xray VLESS" >/dev/null
fi

info "正在启动 Xray..."

systemctl restart xray

sleep 1

if ! systemctl is-active --quiet xray; then
    banner " Xray 启动失败" "$RED"

    journalctl -u xray -n 20 --no-pager

    exit 1
fi

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=${FLOW}&security=reality&type=tcp&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&packetEncoding=xudp"

cat > "$MIHOMO_FILE" <<EOF
- name: VLESS Reality
  type: vless
  server: ${SERVER_IP}
  port: ${PORT}
  uuid: ${UUID}
  network: tcp
  tls: true
  udp: true
  flow: ${FLOW}
  servername: ${SNI}
  client-fingerprint: ${FINGERPRINT}
  packet-encoding: xudp
  reality-opts:
    public-key: ${PUBLIC_KEY}
    short-id: ${SHORT_ID}
EOF

{
    echo "VLESS Link:"
    echo "$VLESS_LINK"
    echo
    echo "Mihomo / Clash:"
    cat "$MIHOMO_FILE"
} > "$CLIENT_FILE"

echo
section "VLESS Link" "$GREEN"
echo
value "$VLESS_LINK"
echo
label " Xray 主配置文件"
path_value "${XRAY_DIR}/config.json"
echo
label " VLESS Reality 协议配置文件"
path_value "$PROTOCOL_CONFIG"
echo
label " 节点信息文件"
path_value "$CLIENT_FILE"
echo
label " Mihomo / Clash config file"
path_value "$MIHOMO_FILE"
echo
section "Mihomo / Clash" "$GREEN"
echo
cat "$MIHOMO_FILE"
echo
