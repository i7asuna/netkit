#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
CONFIG_FILE="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/mieru.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/mieru.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
MIN_MIHOMO_VERSION="1.19.21"

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

cleanup_new_firewall_rules(){
    if $NEW_HAS_TCP; then
        if [[ "$OLD_PORT" != "$PORT" ]] || ! $OLD_HAS_TCP; then
            remove_ufw_port_rule "$PORT" tcp
        fi
    fi

    if $NEW_HAS_UDP; then
        if [[ "$OLD_PORT" != "$PORT" ]] || ! $OLD_HAS_UDP; then
            remove_ufw_port_rule "$PORT" udp
        fi
    fi
}

write_server_listener(){
    local name="$1"
    local transport="$2"

    cat >> "$PROTOCOL_CONFIG" <<EOF
  - name: ${name}
    type: mieru
    port: ${PORT}
    listen: 0.0.0.0
    transport: ${transport}
    users:
      "${USERNAME}": "${PASSWORD}"
EOF
}

write_client_proxy(){
    local transport="$1"

    cat >> "$CLIENT_FILE" <<EOF
- name: Mihomo Mieru ${transport}
  type: mieru
  server: ${YAML_SERVER}
  port: ${PORT}
  transport: ${transport}
  udp: true
  username: ${YAML_USERNAME}
  password: ${YAML_PASSWORD}
  multiplexing: ${MULTIPLEXING}
EOF
}

for package in curl openssl coreutils iproute2; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
        info "正在安装 Mihomo Mieru 环境依赖..."
        apt update
        apt install -y curl openssl coreutils iproute2
        break
    fi
done

if command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN="$(command -v mihomo)"
elif [[ -x /usr/local/bin/mihomo ]]; then
    MIHOMO_BIN="/usr/local/bin/mihomo"
else
    error "请先安装 Mihomo。"
    exit 1
fi

INSTALLED_VERSION=$(
    "$MIHOMO_BIN" -v 2>/dev/null |
    grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
    head -n1 |
    sed 's/^v//' ||
    true
)
if [[ -z "$INSTALLED_VERSION" ]] || \
   ! dpkg --compare-versions "$INSTALLED_VERSION" ge "$MIN_MIHOMO_VERSION"; then
    error "Mieru Listener 需要 Mihomo v${MIN_MIHOMO_VERSION} 或更高版本。"
    error "当前版本：${INSTALLED_VERSION:-未知}，请先更新 Mihomo。"
    exit 1
fi

mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"

SERVER_IP=$(
    curl -4 -fsSL https://api.ipify.org ||
    curl -6 -fsSL https://api64.ipify.org ||
    echo "Unknown"
)

echo
menu_item "1" "TCP"
menu_item "2" "UDP"
menu_item "3" "TCP + UDP"
echo
menu_item "0" "取消"
echo
read -r -p "$(prompt_text "请选择 Mieru 传输模式: ")" TRANSPORT_CHOICE

NEW_HAS_TCP=false
NEW_HAS_UDP=false
case "$TRANSPORT_CHOICE" in
    1)
        NEW_HAS_TCP=true
        DISPLAY_TRANSPORT="TCP"
        ;;
    2)
        NEW_HAS_UDP=true
        DISPLAY_TRANSPORT="UDP"
        ;;
    3)
        NEW_HAS_TCP=true
        NEW_HAS_UDP=true
        DISPLAY_TRANSPORT="TCP + UDP"
        ;;
    0)
        cancel_input "$TRANSPORT_CHOICE"
        exit "$INPUT_CANCEL_STATUS"
        ;;
    *)
        error "无效选择。"
        exit 1
        ;;
esac
echo
menu_item "1" "OFF"
menu_item "2" "LOW（官方建议）"
menu_item "3" "MIDDLE"
menu_item "4" "HIGH"
echo
menu_item "0" "取消"
echo
read -r -p "$(prompt_text "请选择 Mieru 多路复用级别: ")" MULTIPLEXING_CHOICE

case "$MULTIPLEXING_CHOICE" in
    1)
        MULTIPLEXING="MULTIPLEXING_OFF"
        ;;
    2)
        MULTIPLEXING="MULTIPLEXING_LOW"
        ;;
    3)
        MULTIPLEXING="MULTIPLEXING_MIDDLE"
        ;;
    4)
        MULTIPLEXING="MULTIPLEXING_HIGH"
        ;;
    0)
        cancel_input "$MULTIPLEXING_CHOICE"
        exit "$INPUT_CANCEL_STATUS"
        ;;
    *)
        error "无效选择。"
        exit 1
        ;;
esac

read -r -p "$(prompt_text "端口（1-19999，留空随机，输入 0 取消）： ")" PORT
cancel_input "$PORT" && exit "$INPUT_CANCEL_STATUS"
PORT=$(resolve_port "$PORT" 1 19999) || exit 1

USERNAME="netkit-$(openssl rand -hex 6)"
PASSWORD=$(openssl rand -hex 16)
if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    error "Mieru 用户凭据生成失败。"
    exit 1
fi

OLD_PORT=$(yaml_number_field "$PROTOCOL_CONFIG" "port")
OLD_HAS_TCP=false
OLD_HAS_UDP=false
if [[ -f "$PROTOCOL_CONFIG" ]]; then
    if grep -Eq '^[[:space:]]*transport:[[:space:]]*"?TCP"?[[:space:]]*$' "$PROTOCOL_CONFIG"; then
        OLD_HAS_TCP=true
    fi
    if grep -Eq '^[[:space:]]*transport:[[:space:]]*"?UDP"?[[:space:]]*$' "$PROTOCOL_CONFIG"; then
        OLD_HAS_UDP=true
    fi
fi

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

info "正在写入 Mihomo Mieru Listener..."
: > "$PROTOCOL_CONFIG"
if $NEW_HAS_TCP; then
    write_server_listener "mieru-tcp-in" "TCP"
fi
if $NEW_HAS_UDP; then
    write_server_listener "mieru-udp-in" "UDP"
fi

if ! bash "$BUILD_CONFIG_SCRIPT"; then
    rollback_config
    exit 1
fi

FIREWALL_FAILED=false
if command -v ufw >/dev/null 2>&1; then
    if $NEW_HAS_TCP && \
       ! ufw allow "${PORT}/tcp" comment "Mihomo Mieru TCP" >/dev/null; then
        FIREWALL_FAILED=true
    fi
    if $NEW_HAS_UDP && \
       ! ufw allow "${PORT}/udp" comment "Mihomo Mieru UDP" >/dev/null; then
        FIREWALL_FAILED=true
    fi
fi

if $FIREWALL_FAILED; then
    rollback_config
    cleanup_new_firewall_rules
    error "Mieru 防火墙规则添加失败。"
    exit 1
fi

info "正在启动 Mihomo..."
if ! systemctl restart mihomo; then
    rollback_config
    systemctl restart mihomo 2>/dev/null || true
    cleanup_new_firewall_rules
    error "Mihomo 启动失败。"
    journalctl -u mihomo -n 20 --no-pager
    exit 1
fi

sleep 1
if ! systemctl is-active --quiet mihomo; then
    rollback_config
    systemctl restart mihomo 2>/dev/null || true
    cleanup_new_firewall_rules
    error "Mihomo 启动失败。"
    journalctl -u mihomo -n 20 --no-pager
    exit 1
fi

[[ -n "$PROTOCOL_BACKUP" ]] && rm -f "$PROTOCOL_BACKUP"
[[ -n "$CONFIG_BACKUP" ]] && rm -f "$CONFIG_BACKUP"

if [[ -n "$OLD_PORT" ]]; then
    if $OLD_HAS_TCP; then
        if [[ "$OLD_PORT" != "$PORT" ]] || ! $NEW_HAS_TCP; then
            remove_ufw_port_rule "$OLD_PORT" tcp
        fi
    fi
    if $OLD_HAS_UDP; then
        if [[ "$OLD_PORT" != "$PORT" ]] || ! $NEW_HAS_UDP; then
            remove_ufw_port_rule "$OLD_PORT" udp
        fi
    fi
fi

LINK_HOST=$(uri_host "$SERVER_IP")
YAML_SERVER=$(yaml_quote "$SERVER_IP")
YAML_USERNAME=$(yaml_quote "$USERNAME")
YAML_PASSWORD=$(yaml_quote "$PASSWORD")
TCP_LINK=""
UDP_LINK=""
if $NEW_HAS_TCP; then
    TCP_LINK="mierus://${USERNAME}:${PASSWORD}@${LINK_HOST}?profile=default&multiplexing=${MULTIPLEXING}&port=${PORT}&protocol=TCP"
fi
if $NEW_HAS_UDP; then
    UDP_LINK="mierus://${USERNAME}:${PASSWORD}@${LINK_HOST}?profile=default&multiplexing=${MULTIPLEXING}&port=${PORT}&protocol=UDP"
fi

{
    echo "Mieru Link:"
    if $NEW_HAS_TCP && $NEW_HAS_UDP; then
        echo "TCP: ${TCP_LINK}"
        echo "UDP: ${UDP_LINK}"
    elif $NEW_HAS_TCP; then
        echo "$TCP_LINK"
    else
        echo "$UDP_LINK"
    fi
    echo
    echo "Mihomo / Clash:"
} > "$CLIENT_FILE"

if $NEW_HAS_TCP; then
    write_client_proxy "TCP"
fi
if $NEW_HAS_UDP; then
    write_client_proxy "UDP"
fi

banner "Mihomo Mieru 安装成功" "$GREEN"
kv "Server IP :" "$SERVER_IP"
kv "Port      :" "$PORT"
kv "Transport :" "$DISPLAY_TRANSPORT"
kv "Multiplex :" "${MULTIPLEXING#MULTIPLEXING_}"
kv "Username  :" "$USERNAME"
kv "Password  :" "$PASSWORD"
if $NEW_HAS_UDP; then
    kv "Native UDP:" "已开启"
else
    kv "UDP Relay :" "已开启（经 TCP）"
fi
echo
if $NEW_HAS_TCP; then
    label " Mieru TCP Link"
    value "$TCP_LINK"
    echo
fi
if $NEW_HAS_UDP; then
    label " Mieru UDP Link"
    value "$UDP_LINK"
    echo
fi
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
