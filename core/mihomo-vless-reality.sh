#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
CONFIG_FILE="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/vless.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/vless.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"

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
        info "正在安装 Mihomo VLESS 环境依赖..."
        apt update
        apt install -y "${missing[@]}"
    fi
}

check_reality_target(){
    local host="$1"
    local http_version=""
    local curl_output=""

    info "正在检查 Reality 目标站点..."

    if ! curl -V | grep -qi "HTTP2"; then
        error "当前 curl 不支持 HTTP/2，无法执行 Reality 目标检查。"
        return 2
    fi

    curl_output=$(
        curl -Iv --http2 --tlsv1.3 --tls-max 1.3 \
            --connect-timeout 5 --max-time 10 \
            "https://${host}" 2>&1 || true
    )
    http_version=$(
        curl -sSI --http2 --tlsv1.3 --tls-max 1.3 \
            --connect-timeout 5 --max-time 10 \
            -o /dev/null -w "%{http_version}" \
            "https://${host}" || true
    )

    if echo "$curl_output" | grep -qi "TLSv1\.3" && [[ "$http_version" == "2" ]]; then
        success "Reality 目标站点检查通过：TLS 1.3 / HTTP2 可用。"
        return 0
    fi

    warning "目标站点未通过 TLS 1.3 / HTTP2 检查。"
    return 1
}

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

ensure_dependencies

if command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN="$(command -v mihomo)"
elif [[ -x /usr/local/bin/mihomo ]]; then
    MIHOMO_BIN="/usr/local/bin/mihomo"
else
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

while true; do
    read -r -p "$(prompt_text "Reality SNI（默认 icloud.com，输入 0 取消）: ")" SNI_INPUT
    cancel_input "$SNI_INPUT" && exit "$INPUT_CANCEL_STATUS"

    if ! SNI=$(normalize_reality_sni "$SNI_INPUT"); then
        echo
        continue
    fi

    if check_reality_target "$SNI"; then
        break
    else
        check_status=$?
    fi

    [[ "$check_status" -eq 2 ]] && exit 1
    warning "目标站点检查失败，请重新输入 Reality SNI。"
    echo
done

info "正在生成 UUID..."
UUID=$(tr -d '\n' < /proc/sys/kernel/random/uuid)

info "正在生成 Reality 密钥..."
KEY_PAIR=$("$MIHOMO_BIN" generate reality-keypair)
PRIVATE_KEY=$(awk -F': *' 'tolower($1) ~ /private/ { print $2; exit }' <<< "$KEY_PAIR" | xargs)
PUBLIC_KEY=$(awk -F': *' 'tolower($1) ~ /public/ { print $2; exit }' <<< "$KEY_PAIR" | xargs)

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "Reality 密钥生成失败。"
    exit 1
fi

SHORT_ID=$(openssl rand -hex 8)
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

info "正在写入 Mihomo VLESS Listener..."
cat > "$PROTOCOL_CONFIG" <<EOF
  - name: vless-in
    type: vless
    port: ${PORT}
    listen: 0.0.0.0
    udp: true
    users:
      - username: netkit
        uuid: "${UUID}"
        flow: ${FLOW}
    reality-config:
      dest: "${SNI}:443"
      private-key: "${PRIVATE_KEY}"
      short-id:
        - "${SHORT_ID}"
      server-names:
        - "${SNI}"
EOF

if ! bash "$BUILD_CONFIG_SCRIPT"; then
    rollback_config
    exit 1
fi

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" comment "Mihomo VLESS TCP" >/dev/null
    ufw allow "${PORT}/udp" comment "Mihomo VLESS UDP" >/dev/null
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

LINK_HOST=$(uri_host "$SERVER_IP")
YAML_SERVER=$(yaml_quote "$SERVER_IP")
YAML_SNI=$(yaml_quote "$SNI")
YAML_UUID=$(yaml_quote "$UUID")
YAML_FLOW=$(yaml_quote "$FLOW")
YAML_PUBLIC_KEY=$(yaml_quote "$PUBLIC_KEY")
YAML_SHORT_ID=$(yaml_quote "$SHORT_ID")

VLESS_LINK="vless://${UUID}@${LINK_HOST}:${PORT}?encryption=none&flow=${FLOW}&security=reality&type=tcp&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&packetEncoding=xudp"

cat > "$CLIENT_FILE" <<EOF
VLESS Link:
${VLESS_LINK}

Mihomo / Clash:
- name: Mihomo VLESS + TCP + XTLS Vision + REALITY
  type: vless
  server: ${YAML_SERVER}
  port: ${PORT}
  uuid: ${YAML_UUID}
  network: tcp
  tls: true
  udp: true
  tfo: true
  flow: ${YAML_FLOW}
  servername: ${YAML_SNI}
  client-fingerprint: ${FINGERPRINT}
  packet-encoding: xudp
  reality-opts:
    public-key: ${YAML_PUBLIC_KEY}
    short-id: ${YAML_SHORT_ID}
EOF

banner "Mihomo VLESS 安装成功" "$GREEN"
kv "Server IP :" "$SERVER_IP"
kv "Port      :" "$PORT"
kv "UUID      :" "$UUID"
kv "SNI       :" "$SNI"
kv "UDP       :" "已开启"
echo
label " VLESS Link"
value "$VLESS_LINK"
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
