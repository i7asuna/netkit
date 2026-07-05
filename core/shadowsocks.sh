#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/xray-manager"

# shellcheck source=/root/xray-manager/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XRAY_DIR="/usr/local/etc/xray"

PROTOCOL_CONFIG="${XRAY_DIR}/protocols/shadowsocks.json"
CLIENT_FILE="${XRAY_DIR}/client/shadowsocks.txt"
MIHOMO_FILE="${XRAY_DIR}/client/shadowsocks-mihomo.yaml"

METHOD="2022-blake3-aes-256-gcm"

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

mkdir -p "${XRAY_DIR}/protocols" "${XRAY_DIR}/client"

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

info "正在生成密码..."

PASSWORD=$(openssl rand -base64 32 | tr -d '\n')

info "正在保存 Shadowsocks 协议配置..."

cat > "$PROTOCOL_CONFIG" <<EOF
{
  "listen": "::",
  "port": $PORT,
  "protocol": "shadowsocks",
  "settings": {
    "method": "$METHOD",
    "password": "$PASSWORD",
    "network": "tcp,udp"
  },
  "streamSettings": {
    "sockopt": {
      "tcpFastOpen": true,
      "tcpNoDelay": true
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
    ufw allow "${PORT}/tcp" comment "Xray Shadowsocks TCP" >/dev/null

    ufw status | grep -q "${PORT}/udp" || \
    ufw allow "${PORT}/udp" comment "Xray Shadowsocks UDP" >/dev/null
fi

info "正在启动 Xray..."

systemctl restart xray
sleep 1

if ! systemctl is-active --quiet xray; then
    banner " Xray 启动失败" "$RED"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

SS_BASE64=$(printf "%s:%s" "$METHOD" "$PASSWORD" | base64 | tr -d '\n')
SS_LINK="ss://${SS_BASE64}@${SERVER_IP}:${PORT}"

cat > "$MIHOMO_FILE" <<EOF
- name: Shadowsocks
  type: ss
  server: ${SERVER_IP}
  port: ${PORT}
  cipher: ${METHOD}
  password: ${PASSWORD}
  udp: true
EOF

{
    echo "SS Link:"
    echo "$SS_LINK"
    echo
    echo "Mihomo / Clash:"
    cat "$MIHOMO_FILE"
} > "$CLIENT_FILE"

banner "    Shadowsocks 安装成功" "$GREEN"
kv "Server IP :" "$SERVER_IP"
kv "Port      :" "$PORT"
kv "Method    :" "$METHOD"
kv "Password  :" "$PASSWORD"
echo
section "SS Link" "$GREEN"
echo
value "$SS_LINK"
echo
label " Xray 主配置文件"
path_value "${XRAY_DIR}/config.json"
echo
label " Shadowsocks 协议配置文件"
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
divider "$GREEN"
