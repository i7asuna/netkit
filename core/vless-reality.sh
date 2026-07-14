#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XRAY_DIR="/usr/local/etc/xray"

CONFIG_FILE="${XRAY_DIR}/config.json"
PROTOCOL_CONFIG="${XRAY_DIR}/protocols/vless.json"
CLIENT_FILE="${XRAY_DIR}/client/vless.txt"

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
        info "正在安装 VLESS + TCP + XTLS Vision + REALITY 环境依赖..."
        apt update
        apt install -y "${missing[@]}"
    fi
}

check_reality_target(){
    local host="$1"
    local http_version=""
    local curl_output=""

    info "正在检查 Reality 目标站点..."

    if [[ "$host" != *.* ]]; then
        warning "目标站点看起来不像有效域名：${host}"
        return 1
    fi

    if ! curl -V | grep -qi "HTTP2"; then
        error "当前 curl 不支持 HTTP/2，无法执行 --http2 检查。"
        error "请安装支持 HTTP/2 的 curl 后重试。"
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
            -o /dev/null \
            -w "%{http_version}" \
            "https://${host}" || true
    )

    if echo "$curl_output" | grep -qi "TLSv1\.3" && [[ "$http_version" == "2" ]]; then
        success "Reality 目标站点检查通过：TLS 1.3 / HTTP2 可用。"
        return
    fi

    if ! echo "$curl_output" | grep -qi "TLSv1\.3"; then
        warning "目标站点未通过 TLS 1.3 检查。"
    fi

    if [[ "$http_version" != "2" ]]; then
        warning "目标站点未通过 HTTP/2 检查。"
    fi

    return 1
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

PORT=$(resolve_port "$PORT") || exit 1

while true; do
    read -r -p "$(prompt_text "Reality SNI（默认 icloud.com）: ")" SNI_INPUT

    if ! SNI=$(normalize_reality_sni "$SNI_INPUT"); then
        warning "请重新输入 Reality SNI。"
        echo
        continue
    fi

    if check_reality_target "$SNI"; then
        break
    else
        check_status=$?
    fi

    if [[ "$check_status" -eq 2 ]]; then
        exit 1
    fi

    warning "目标站点检查失败，请重新输入 Reality SNI。"
    echo
done

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

info "正在写入 VLESS + TCP + XTLS Vision + REALITY 协议配置..."

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
if ! bash /root/netkit/config/build_config.sh; then
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
    exit 1
fi
[[ -n "$PROTOCOL_BACKUP" ]] && rm -f "$PROTOCOL_BACKUP"
[[ -n "$CONFIG_BACKUP" ]] && rm -f "$CONFIG_BACKUP"

info "正在更新防火墙..."

if command -v ufw >/dev/null 2>&1; then
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

LINK_HOST=$(uri_host "$SERVER_IP")
YAML_SERVER=$(yaml_quote "$SERVER_IP")
YAML_SNI=$(yaml_quote "$SNI")
YAML_UUID=$(yaml_quote "$UUID")
YAML_FLOW=$(yaml_quote "$FLOW")
YAML_FINGERPRINT=$(yaml_quote "$FINGERPRINT")
YAML_PUBLIC_KEY=$(yaml_quote "$PUBLIC_KEY")
YAML_SHORT_ID=$(yaml_quote "$SHORT_ID")

VLESS_LINK="vless://${UUID}@${LINK_HOST}:${PORT}?encryption=none&flow=${FLOW}&security=reality&type=tcp&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&packetEncoding=xudp"

cat > "$CLIENT_FILE" <<EOF
VLESS Link:
${VLESS_LINK}

Mihomo / Clash:
- name: VLESS + TCP + XTLS Vision + REALITY
  type: vless
  server: ${YAML_SERVER}
  port: ${PORT}
  uuid: ${YAML_UUID}
  network: tcp
  tls: true
  udp: true
  flow: ${YAML_FLOW}
  servername: ${YAML_SNI}
  client-fingerprint: ${YAML_FINGERPRINT}
  packet-encoding: xudp
  reality-opts:
    public-key: ${YAML_PUBLIC_KEY}
    short-id: ${YAML_SHORT_ID}
EOF

echo
label " VLESS Link"
echo
value "$VLESS_LINK"
echo
label " Xray 主配置文件"
path_value "${XRAY_DIR}/config.json"
echo
label " VLESS + TCP + XTLS Vision + REALITY 协议配置文件"
path_value "$PROTOCOL_CONFIG"
echo
label " 连接信息文件"
path_value "$CLIENT_FILE"
echo
label " Mihomo / Clash YAML"
echo
sed -n '/^Mihomo \/ Clash:/,$p' "$CLIENT_FILE" | tail -n +2 | while IFS= read -r line; do
    value "$line"
done
echo
