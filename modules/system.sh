#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

TIMEZONE="Asia/Hong_Kong"

set_timezone(){
    header "时区调整"

    if ! require_commands timedatectl; then
        pause
        return
    fi

    if ! timedatectl set-timezone "$TIMEZONE"; then
        error "时区调整失败，请确认系统使用 systemd。"
        pause
        return
    fi

    success "时区已调整为 ${TIMEZONE}。"
    pause
}

configure_auto_updates(){
    header "自动更新与自动重启"
    warning "启用后将每天检查并安装更新；如系统要求重启，将在 03:30 自动重启。"

    info "正在配置系统自动更新..."

    if ! require_commands apt systemctl; then
        pause
        return
    fi

    if ! apt update || ! apt install -y unattended-upgrades apt-listchanges; then
        error "自动更新所需软件包安装失败。"
        pause
        return
    fi

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
OnCalendar=*-*-* 03:15:00
RandomizedDelaySec=0
Persistent=true
EOF

    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    if ! systemctl daemon-reload || \
       ! systemctl enable --now apt-daily.timer apt-daily-upgrade.timer; then
        error "自动更新定时器启用失败。"
        pause
        return
    fi

    success "自动更新已启用。"
    kv "更新软件列表:" "03:00"
    kv "安装系统更新:" "03:15"
    kv "需要时重启  :" "03:30"
    pause
}
