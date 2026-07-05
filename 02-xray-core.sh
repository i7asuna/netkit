#!/usr/bin/env bash

set -Eeuo pipefail

XRAY_DIR="/usr/local/etc/xray"

echo "==> Updating package list..."

apt update

echo "==> Installing dependencies..."

apt install -y \
    curl \
    ca-certificates

echo "==> Installing Xray..."

bash <(
    curl -fsSL -L \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
) install

echo "==> Checking Xray..."

if command -v xray >/dev/null 2>&1; then
    XRAY_BIN="$(command -v xray)"
elif [[ -x /usr/local/bin/xray ]]; then
    XRAY_BIN="/usr/local/bin/xray"
elif [[ -x /usr/bin/xray ]]; then
    XRAY_BIN="/usr/bin/xray"
else
    echo "Xray installation failed."
    exit 1
fi

echo "==> Preparing directories..."

mkdir -p \
    "${XRAY_DIR}" \
    "${XRAY_DIR}/protocols" \
    "${XRAY_DIR}/client"

echo "==> Creating default outbound..."

cat > "${XRAY_DIR}/outbound.json" <<EOF
{
  "protocol": "freedom",
  "settings": {}
}
EOF

echo "==> Enabling Xray service..."

systemctl enable xray

# Some versions of Xray-install automatically start the service.
# Stop it now and restart after the protocol configuration is generated.
systemctl stop xray 2>/dev/null || true

echo
echo "=========================================="
echo "         Xray Core Installed"
echo "=========================================="
echo

"$XRAY_BIN" version | head -n1

echo
echo "Binary           : $XRAY_BIN"
echo "Config Directory : ${XRAY_DIR}"
echo "Protocols        : ${XRAY_DIR}/protocols"
echo "Clients          : ${XRAY_DIR}/client"

echo
echo "=========================================="
echo "Installation completed."
echo "Xray service has been enabled."
echo "Service will be started after protocol configuration."
echo "=========================================="