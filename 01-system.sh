#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Variables
########################################

SSH_CONFIG="/etc/ssh/sshd_config"

FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"

SYSCTL_CONFIG="/etc/sysctl.d/99-z-bbr.conf"

SWAPFILE="/swapfile"

TIMEZONE="Asia/Hong_Kong"

echo "==> Updating package list..."

apt update

echo "==> Installing dependencies..."

apt install -y \
    openssl \
    openssh-server \
    python3-systemd \
    net-tools \
    ufw \
    fail2ban

echo "==> Configuring SSH..."

read -rp "SSH Port: " SSH_PORT

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || \
   [[ "$SSH_PORT" -lt 1 ]] || \
   [[ "$SSH_PORT" -gt 65535 ]]; then

    echo "Invalid SSH port."

    exit 1

fi

if ss -ltnH | awk '{print $4}' | grep -q ":${SSH_PORT}$"; then

    echo "Port already in use."

    exit 1

fi

echo

read -rp "SSH Public Key: " PUBLIC_KEY

if [[ -z "$PUBLIC_KEY" ]]; then

    echo "SSH Public Key cannot be empty."

    exit 1

fi

mkdir -p /root/.ssh

chmod 700 /root/.ssh

echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys

chmod 600 /root/.ssh/authorized_keys


echo "==> Applying SSH configuration..."

declare -A SSH_CONFIGS=(
    ["Port"]="$SSH_PORT"
    ["PasswordAuthentication"]="no"
    ["PubkeyAuthentication"]="yes"
    ["PermitRootLogin"]="prohibit-password"
)

NEW_CONFIG=""

for KEY in "${!SSH_CONFIGS[@]}"; do

    sed -i "/^[#[:space:]]*${KEY}[[:space:]]/d" "$SSH_CONFIG"

    NEW_CONFIG+="${KEY} ${SSH_CONFIGS[$KEY]}"$'\n'

done

awk -v CONFIG="$NEW_CONFIG" '

/^[[:space:]]*Match/ && !DONE {

    printf "%s", CONFIG

    DONE=1

}

{

    print

}

END {

    if (!DONE)

        printf "%s", CONFIG

}

' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp"

mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"

echo "==> Configuring firewall..."

ufw allow "${SSH_PORT}/tcp" comment "SSH"

ufw delete allow 22/tcp >/dev/null 2>&1 || true

ufw delete allow OpenSSH >/dev/null 2>&1 || true

echo "==> Configuring Fail2Ban..."

cat > "$FAIL2BAN_CONFIG" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 604800
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 3
bantime = 604800
EOF


read -rp "Create 1G Swap? [y/n]: " CREATE_SWAP

CREATE_SWAP=${CREATE_SWAP:-y}

SWAP_STATUS="Skipped"

if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then

    echo "==> Creating swap..."

    if [[ -z "$(swapon --show)" ]]; then

        fallocate -l 1G "$SWAPFILE" || \
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024

        chmod 600 "$SWAPFILE"

        mkswap "$SWAPFILE"

        swapon "$SWAPFILE"

        grep -q "^${SWAPFILE}" /etc/fstab || \
        echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab

        SWAP_STATUS="Created"

    else

        SWAP_STATUS="Already Exists"

    fi

else

    echo "==> Skipping swap..."

fi

echo "==> Configuring timezone..."

timedatectl set-timezone "$TIMEZONE"

echo "==> Applying system optimization..."

modprobe nf_conntrack 2>/dev/null || true

echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

cat > "$SYSCTL_CONFIG" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.netfilter.nf_conntrack_max = 32768
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

net.core.somaxconn = 1024
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_mtu_probing = 1

vm.swappiness = 10
EOF

sysctl --system >/dev/null

echo "==> Restarting services..."

systemctl restart ssh

ufw --force enable >/dev/null

ufw --force reload

systemctl enable fail2ban

systemctl restart fail2ban

echo

echo "=========================================="

echo "     System Configuration Summary"

echo "=========================================="

echo

echo " SSH Port    : $SSH_PORT"
echo " SSH Auth    : Key Only"

echo

echo " Firewall    : $(ufw status | grep -q active && echo Enabled || echo Disabled)"
echo " Fail2Ban    : $(systemctl is-active --quiet fail2ban && echo Enabled || echo Disabled)"

echo

echo " Swap        : $SWAP_STATUS"
echo " Timezone    : $TIMEZONE"

echo

echo " TCP CC      : bbr"
echo " Qdisc       : fq"

echo

echo