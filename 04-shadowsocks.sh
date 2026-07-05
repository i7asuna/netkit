#!/usr/bin/env bash

set -Eeuo pipefail

XRAY_DIR="/usr/local/etc/xray"

PROTOCOL_CONFIG="${XRAY_DIR}/protocols/shadowsocks.json"
CLIENT_FILE="${XRAY_DIR}/client/shadowsocks.txt"

METHOD="2022-blake3-aes-256-gcm"

echo "==> Checking Xray..."

if command -v xray >/dev/null 2>&1; then

    XRAY_BIN=$(command -v xray)

elif [[ -x /usr/local/bin/xray ]]; then

    XRAY_BIN="/usr/local/bin/xray"

elif [[ -x /usr/bin/xray ]]; then

    XRAY_BIN="/usr/bin/xray"

else

    echo "Please install Xray Core first."

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

read -rp "Port (default random): " PORT

if [[ -z "$PORT" ]]; then

    while :; do

        PORT=$(shuf -i 30000-60000 -n1)

        ss -ltnH | awk '{print $4}' | grep -q ":${PORT}$" || break

    done

fi

echo "==> Generating Password..."

PASSWORD=$(openssl rand -base64 32 | tr -d '\n')

echo "==> Saving protocol..."

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
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
    ],
    "routeOnly": true
  },
  "sockopt": {
    "tcpFastOpen": true,
    "tcpNoDelay": true
  }
}
EOF


echo "==> Building configuration..."
if ! bash /root/xray-manager/build_config.sh; then
			exit 1
if

echo "==> Updating firewall..."

if command -v ufw >/dev/null 2>&1; then

    ufw status | grep -q "${PORT}/tcp" || \
    ufw allow "${PORT}/tcp" comment "Xray Shadowsocks TCP" >/dev/null

    ufw status | grep -q "${PORT}/udp" || \
    ufw allow "${PORT}/udp" comment "Xray Shadowsocks UDP" >/dev/null

fi

echo "==> Starting Xray..."

systemctl restart xray

sleep 1

if ! systemctl is-active --quiet xray; then

    echo
    echo "=========================================="
    echo " Xray failed to start"
    echo "=========================================="
    echo

    journalctl -u xray -n 20 --no-pager

    exit 1

fi

SS_BASE64=$(printf "%s:%s" "$METHOD" "$PASSWORD" | base64 | tr -d '\n')

SS_LINK="ss://${SS_BASE64}@${SERVER_IP}:${PORT}"

echo "$SS_LINK" > "$CLIENT_FILE"

echo
echo "=========================================="
echo "    Shadowsocks Installed Successfully"
echo "=========================================="
echo
echo " Server IP : $SERVER_IP"
echo " Port      : $PORT"
echo " Method    : $METHOD"
echo " Password  : $PASSWORD"
echo
echo "================== SS Link =================="
echo
echo " ss:$SS_LINK"
echo
echo " Config File"
echo " ${XRAY_DIR}/config.json"
echo
echo " Protocol File"
echo " $PROTOCOL_CONFIG"
echo
echo " Client File"
echo " $CLIENT_FILE"
echo
echo "=========================================="
