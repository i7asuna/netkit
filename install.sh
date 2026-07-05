#!/usr/bin/env bash
set -Eeuo pipefail

RED="\033[31m"
GREEN="\033[92m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

divider(){
    local color="${1:-$CYAN}"
    local char="${2:-=}"
    local width="${3:-34}"
    local line

    line=$(printf "%${width}s" "")
    line="${line// /$char}"
    echo -e "${color}${line}${RESET}"
}

banner(){
    local text="$1"
    local color="${2:-$CYAN}"

    divider "$color"
    echo -e "${color}${text}${RESET}"
    divider "$color"
}

info(){
    echo -e "${CYAN}==> $1${RESET}"
}

success(){
    echo
    echo -e "${GREEN}$1${RESET}"
}

warning(){
    echo
    echo -e "${YELLOW}$1${RESET}"
}

configure_debian_auto_updates(){
    info "Configuring Debian automatic updates..."

    apt update
    apt install -y unattended-upgrades apt-listchanges

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    cat > /etc/apt/apt.conf.d/51unattended-upgrades-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
EOF

    mkdir -p /etc/systemd/system/apt-daily.timer.d
    cat > /etc/systemd/system/apt-daily.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=0
Persistent=true
EOF

    mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
    cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:10:00
RandomizedDelaySec=0
Persistent=true
EOF

    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

REPO="https://github.com/7o1ove/xray-manager.git"
INSTALL_DIR="/root/xray-manager"
COMMAND_NAME="7o1ove"
COMMAND_PATH="/usr/local/bin/${COMMAND_NAME}"

banner "Installing Xray Manager..." "$CYAN"

if [ -d "$INSTALL_DIR/.git" ]; then
    warning "Directory exists, updating..."

    cd "$INSTALL_DIR"

    info "Force syncing with remote..."
    git fetch origin
    git reset --hard origin/main
    git clean -fd

else
    info "Cloning repo..."
    git clone "$REPO" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

chmod +x *.sh 2>/dev/null || true
chmod +x core/*.sh 2>/dev/null || true
chmod +x system/*.sh 2>/dev/null || true
chmod +x config/*.sh 2>/dev/null || true
chmod +x lib/*.sh 2>/dev/null || true

configure_debian_auto_updates

info "Creating global command: ${COMMAND_NAME}"

mkdir -p "$(dirname "$COMMAND_PATH")"

cat > "$COMMAND_PATH" <<EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR"
exec bash "$INSTALL_DIR/xray-manager.sh" "\$@"
EOF

chmod +x "$COMMAND_PATH"
hash -r 2>/dev/null || true

banner "Installation completed!" "$GREEN"
success "Run '${COMMAND_NAME}' next time to open Xray Manager."
info "Starting Xray Manager..."
echo

bash xray-manager.sh </dev/tty
