#!/usr/bin/env bash

set -Eeuo pipefail

XRAY_DIR="/usr/local/etc/xray"

PROTOCOL_CONFIG="${XRAY_DIR}/protocols/vless.json"
CLIENT_FILE="${XRAY_DIR}/client/vless.txt"

FLOW="xtls-rprx-vision"
FINGERPRINT="chrome"

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

read -rp "Reality SNI (default: icloud.com): " SNI

SNI=${SNI:-icloud.com}
SNI=${SNI#https://}
SNI=${SNI#http://}
SNI=${SNI%/}

echo "==> Generating UUID..."

UUID=$("$XRAY_BIN" uuid | xargs)

echo "==> Generating Reality Key..."

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
    echo "Failed to generate Reality keys."
    exit 1
fi

echo "==> Generating Short ID..."

SHORT_ID=$(openssl rand -hex 8)

echo "==> Writing VLESS protocol..."

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

echo "==> Building configuration..."
if ! bash /root/xray-manager/config/build_config.sh; then
    exit 1
fi

echo "==> Updating firewall..."

if command -v ufw >/dev/null 2>&1; then
    ufw status | grep -q "${PORT}/tcp" || \
    ufw allow "${PORT}/tcp" comment "Xray VLESS" >/dev/null
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

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=${FLOW}&security=reality&type=tcp&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&packetEncoding=xudp"

echo "$VLESS_LINK" > "$CLIENT_FILE"

echo
echo "================= VLESS Link ================="
echo
echo " $VLESS_LINK"
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
