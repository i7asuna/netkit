#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

XANMOD_SCRIPT="${SCRIPT_DIR}/system/xanmod-kernel.sh"
TIMEZONE="Asia/Hong_Kong"
XANMOD_APT_SOURCE="/etc/apt/sources.list.d/xanmod-release.list"
XANMOD_UNATTENDED_CONFIG="/etc/apt/apt.conf.d/52unattended-upgrades-xanmod"

install_xanmod_kernel(){
    if ! run_script "$XANMOD_SCRIPT"; then
        error "XanMod 内核安装未完成。"
    fi
    pause
}

set_timezone(){
    header "时区调整"
    timedatectl set-timezone "$TIMEZONE"
    success "时区已调整为 ${TIMEZONE}。"
    pause
}

configure_auto_updates(){
    local current_kernel
    local xanmod_updates_status="未启用"

    current_kernel=$(uname -r)
    header "自动更新与自动重启"
    warning "启用后将每天检查并安装更新；如系统要求重启，将在 03:30 自动重启。"

    info "正在配置系统自动更新..."

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

    if [[ "${current_kernel,,}" == *xanmod* ]]; then
        if [[ -r "$XANMOD_APT_SOURCE" ]] && \
            grep -Eq '^[[:space:]]*deb[[:space:]].*deb\.xanmod\.org' "$XANMOD_APT_SOURCE"; then
            cat > "$XANMOD_UNATTENDED_CONFIG" <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "site=deb.xanmod.org";
};
EOF
            xanmod_updates_status="已启用"
            info "检测到当前运行 XanMod，已允许自动安装 XanMod 内核更新。"
        else
            rm -f "$XANMOD_UNATTENDED_CONFIG"
            xanmod_updates_status="未启用（仓库缺失）"
            warning "当前运行 XanMod，但未检测到可用的 XanMod APT 仓库。"
        fi
    else
        rm -f "$XANMOD_UNATTENDED_CONFIG"
        xanmod_updates_status="未启用（当前非 XanMod）"
        info "当前内核不是 XanMod，仅启用系统仓库自动更新。"
    fi

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
    systemctl daemon-reload
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

    success "自动更新已启用。"
    kv "更新软件列表:" "03:00"
    kv "安装系统更新:" "03:15"
    kv "需要时重启  :" "03:30"
    kv "XanMod 内核更新:" "$xanmod_updates_status"
    pause
}
