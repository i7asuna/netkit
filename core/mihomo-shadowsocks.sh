#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
CONFIG_FILE="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/shadowsocks.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/shadowsocks.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
METHOD="2022-blake3-aes-256-gcm"

rollback_config(){
    if [[ -n "$PROTOCOL_BACKUP" && -f "$PROTOCOL_BACKUP" ]]; then
        mv "$PROTOCOL_BACKUP" "$PROTOCOL_CONFIG"
    else
        rm -f "$PROTOCOL_CONFIG"
    fi

    if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
        mv "$CONFIG_BACKUP" "$CONFIG_FILE"
    else
        rm -f "$CONFIG_FILE"
    fi
}

for package in curl openssl coreutils iproute2; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
        info "正在安装 Mihomo Shadowsocks 环境依赖..."
        apt update
        apt install -y curl openssl coreutils iproute2
        break
    fi
done

if ! command -v mihomo >/dev/null 2>&1 && [[ ! -x /usr/local/bin/mihomo ]]; then
    error "请先安装 Mihomo。"
    exit 1
fi

mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"

SERVER_IP=$(
    curl -4 -fsSL https://api.ipify.org ||
    curl -6 -fsSL https://api64.ipify.org ||
    echo "Unknown"
)

read -r -p "$(prompt_text "端口（留空随机，输入 0 取消）: ")" PORT
cancel_input "$PORT" && exit "$INPUT_CANCEL_STATUS"
PORT=$(resolve_port "$PORT") || exit 1

PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
if [[ -z "$PASSWORD" ]]; then
    error "Shadowsocks 密钥生成失败。"
    exit 1
fi

OLD_PORT=$(yaml_number_field "$PROTOCOL_CONFIG" "port")

PROTOCOL_BACKUP=""
if [[ -f "$PROTOCOL_CONFIG" ]]; then
    PROTOCOL_BACKUP="${PROTOCOL_CONFIG}.bak.$$"
    cp "$PROTOCOL_CONFIG" "$PROTOCOL_BACKUP"
fi

CONFIG_BACKUP=""
if [[ -f "$CONFIG_FILE" ]]; then
    CONFIG_BACKUP="${CONFIG_FILE}.bak.$$"
    cp "$CONFIG_FILE" "$CONFIG_BACKUP"
fi

info "正在写入 Mihomo Shadowsocks Listener..."
cat > "$PROTOCOL_CONFIG" <<EOF
  - name: shadowsocks-in
    type: shadowsocks
    port: ${PORT}
    listen: 0.0.0.0
    cipher: ${METHOD}
    password: "${PASSWORD}"
    udp: true
EOF

if ! bash "$BUILD_CONFIG_SCRIPT"; then
    rollback_config
    exit 1
fi

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" comment "Mihomo Shadowsocks TCP" >/dev/null
    ufw allow "${PORT}/udp" comment "Mihomo Shadowsocks UDP" >/dev/null
fi

info "正在启动 Mihomo..."
if ! systemctl restart mihomo; then
    rollback_config
    systemctl restart mihomo 2>/dev/null || true
    if [[ "$OLD_PORT" != "$PORT" ]]; then
        remove_ufw_port_rule "$PORT" tcp
        remove_ufw_port_rule "$PORT" udp
    fi
    error "Mihomo 启动失败。"
    journalctl -u mihomo -n 20 --no-pager
    exit 1
fi

sleep 1
if ! systemctl is-active --quiet mihomo; then
    rollback_config
    systemctl restart mihomo 2>/dev/null || true
    if [[ "$OLD_PORT" != "$PORT" ]]; then
        remove_ufw_port_rule "$PORT" tcp
        remove_ufw_port_rule "$PORT" udp
    fi
    error "Mihomo 启动失败。"
    journalctl -u mihomo -n 20 --no-pager
    exit 1
fi

[[ -n "$PROTOCOL_BACKUP" ]] && rm -f "$PROTOCOL_BACKUP"
[[ -n "$CONFIG_BACKUP" ]] && rm -f "$CONFIG_BACKUP"

if [[ -n "$OLD_PORT" && "$OLD_PORT" != "$PORT" ]]; then
    remove_ufw_port_rule "$OLD_PORT" tcp
    remove_ufw_port_rule "$OLD_PORT" udp
fi

SS_BASE64=$(printf "%s:%s" "$METHOD" "$PASSWORD" | base64 | tr '/+' '_-' | tr -d '=\n')
LINK_HOST=$(uri_host "$SERVER_IP")
YAML_SERVER=$(yaml_quote "$SERVER_IP")
YAML_METHOD=$(yaml_quote "$METHOD")
YAML_PASSWORD=$(yaml_quote "$PASSWORD")
SS_LINK="ss://${SS_BASE64}@${LINK_HOST}:${PORT}"

cat > "$CLIENT_FILE" <<EOF
SS Link:
${SS_LINK}

Mihomo / Clash:
- name: Mihomo Shadowsocks
  type: ss
  server: ${YAML_SERVER}
  port: ${PORT}
  cipher: ${YAML_METHOD}
  password: ${YAML_PASSWORD}
  udp: true
EOF

banner "Mihomo Shadowsocks 安装成功" "$GREEN"
kv "Server IP :" "$SERVER_IP"
kv "Port      :" "$PORT"
kv "Method    :" "$METHOD"
kv "Password  :" "$PASSWORD"
kv "UDP       :" "已开启"
echo
label " Shadowsocks Link"
value "$SS_LINK"
echo
path_kv "主配置文件      :" "$CONFIG_FILE"
path_kv "协议配置文件    :" "$PROTOCOL_CONFIG"
path_kv "连接信息文件    :" "$CLIENT_FILE"
echo
label " Mihomo / Clash YAML"
echo
sed -n '/^Mihomo \/ Clash:/,$p' "$CLIENT_FILE" | tail -n +2 | while IFS= read -r line; do
    value "$line"
done
echo
divider "$GREEN"
