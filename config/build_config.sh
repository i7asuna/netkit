#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XRAY_DIR="/usr/local/etc/xray"

CONFIG_FILE="${XRAY_DIR}/config.json"
PROTOCOL_DIR="${XRAY_DIR}/protocols"
OUTBOUND_FILE="${XRAY_DIR}/outbound.json"

info "正在构建 Xray 配置..."

mkdir -p "$XRAY_DIR"
mkdir -p "$PROTOCOL_DIR"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Find Xray

if command -v xray >/dev/null 2>&1; then

    XRAY_BIN=$(command -v xray)

elif [[ -x /usr/local/bin/xray ]]; then

    XRAY_BIN="/usr/local/bin/xray"

elif [[ -x /usr/bin/xray ]]; then

    XRAY_BIN="/usr/bin/xray"

else

    error "未检测到 Xray。"

    exit 1

fi

# Ensure outbound

if [[ ! -f "$OUTBOUND_FILE" ]]; then

    warning "未找到出站配置，正在创建默认出站配置..."

    cat > "$OUTBOUND_FILE" <<EOF
{
  "protocol": "freedom",
  "settings": {}
}
EOF

fi

# Check inbound

FOUND=false

for FILE in "$PROTOCOL_DIR"/*.json; do

    if [[ -f "$FILE" ]]; then

        FOUND=true

        break

    fi

done

if ! $FOUND; then

    error "未找到协议配置。"

    exit 1

fi

# Write config.json

cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "inbounds": [

EOF

FIRST=true

for FILE in "$PROTOCOL_DIR"/*.json; do

    [[ -f "$FILE" ]] || continue

    if $FIRST; then

        FIRST=false

    else

        echo "," >> "$CONFIG_FILE"

    fi

    cat "$FILE" >> "$CONFIG_FILE"

    echo >> "$CONFIG_FILE"

done

cat >> "$CONFIG_FILE" <<EOF

  ],

  "outbounds": [

EOF

cat "$OUTBOUND_FILE" >> "$CONFIG_FILE"

echo >> "$CONFIG_FILE"

cat >> "$CONFIG_FILE" <<EOF

  ]
}
EOF

# Test

info "正在测试 Xray 配置..."

if ! "$XRAY_BIN" run -test -config "$CONFIG_FILE"; then

    banner "配置测试失败" "$RED"

    exit 1

fi

banner "配置构建成功" "$GREEN"
echo
label " Xray 主配置文件"
path_value "$CONFIG_FILE"
echo
divider "$GREEN"
