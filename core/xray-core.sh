#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/xray-manager"

# shellcheck source=/root/xray-manager/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XRAY_DIR="/usr/local/etc/xray"

info "Updating package list..."

apt update

info "Installing dependencies..."

apt install -y \
    curl \
    ca-certificates

info "Installing Xray..."

bash <(
    curl -fsSL -L \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
) install

info "Checking Xray..."

if command -v xray >/dev/null 2>&1; then
    XRAY_BIN="$(command -v xray)"
elif [[ -x /usr/local/bin/xray ]]; then
    XRAY_BIN="/usr/local/bin/xray"
elif [[ -x /usr/bin/xray ]]; then
    XRAY_BIN="/usr/bin/xray"
else
    error "Xray installation failed."
    exit 1
fi

info "Preparing directories..."

mkdir -p \
    "${XRAY_DIR}" \
    "${XRAY_DIR}/protocols" \
    "${XRAY_DIR}/client"

info "Creating default outbound..."

cat > "${XRAY_DIR}/outbound.json" <<EOF
{
  "protocol": "freedom",
  "settings": {}
}
EOF

info "Enabling Xray service..."

systemctl enable xray

# Some versions of Xray-install automatically start the service.
# Stop it now and restart after the protocol configuration is generated.
systemctl stop xray 2>/dev/null || true

banner "         Xray Core Installed" "$GREEN"

value "$("$XRAY_BIN" version | head -n1)"

echo
path_kv "Binary           :" "$XRAY_BIN"
path_kv "Config Directory :" "${XRAY_DIR}"
path_kv "Protocols        :" "${XRAY_DIR}/protocols"
path_kv "Clients          :" "${XRAY_DIR}/client"

echo
divider "$GREEN"
echo -e "${GREEN}Installation completed.${RESET}"
echo -e "${GREEN}Xray service has been enabled.${RESET}"
echo -e "${GREEN}Service will be started after protocol configuration.${RESET}"
divider "$GREEN"
