#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/xray-manager"

# shellcheck source=/root/xray-manager/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

INSTALL_SCRIPT="${SCRIPT_DIR}/core/xray-core.sh"
VLESS_SCRIPT="${SCRIPT_DIR}/core/vless-reality.sh"
SS_SCRIPT="${SCRIPT_DIR}/core/shadowsocks.sh"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/build_config.sh"

XRAY_SERVICE="xray"
XRAY_DIR="/usr/local/etc/xray"
PROTOCOL_DIR="${XRAY_DIR}/protocols"
CLIENT_DIR="${XRAY_DIR}/client"
IPV6_SYSCTL_CONFIG="/etc/sysctl.d/99-xray-manager-ipv6.conf"
SYSCTL_CONFIG="/etc/sysctl.d/99-z-bbr.conf"
SWAPFILE="/swapfile"
TIMEZONE="Asia/Hong_Kong"

header(){
    clear
    divider "$CYAN"
    echo -e "${CYAN}             Xray Manager${RESET}"
    divider "$CYAN"
}

run_script(){
    local file="$1"

    if [[ ! -f "$file" ]]; then
        error "脚本不存在: $file"
        pause
        return 1
    fi

    bash "$file"
}

valid_port(){
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

split_items(){
    local input="$1"
    input=${input//,/ }
    printf '%s\n' $input
}

current_ssh_port(){
    awk '
        /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
            print $2
            found=1
            exit
        }
        END {
            if (!found)
                print 22
        }
    ' /etc/ssh/sshd_config
}

restart_ssh_service(){
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        systemctl restart ssh
    else
        systemctl restart sshd
    fi
}

set_sshd_options(){
    local new_config=""
    local key

    for key in "$@"; do
        sed -i "/^[#[:space:]]*${key%%=*}[[:space:]]/d" /etc/ssh/sshd_config
        new_config+="${key%%=*} ${key#*=}"$'\n'
    done

    awk -v CONFIG="$new_config" '
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
' /etc/ssh/sshd_config > /etc/ssh/sshd_config.tmp

    mv /etc/ssh/sshd_config.tmp /etc/ssh/sshd_config
}

ensure_apt_package(){
    local package="$1"

    if dpkg -s "$package" >/dev/null 2>&1; then
        success "${package} 已安装。"
        return
    fi

    info "正在安装 ${package}..."
    apt update
    apt install -y "$package"
}

rebuild_or_stop_xray(){
    local found=false
    local file

    for file in "$PROTOCOL_DIR"/*.json; do
        if [[ -f "$file" ]]; then
            found=true
            break
        fi
    done

    if $found; then
        bash "$BUILD_CONFIG_SCRIPT"
        systemctl restart "$XRAY_SERVICE"
        success "Xray 配置已重建并重启。"
    else
        rm -f "${XRAY_DIR}/config.json"
        systemctl stop "$XRAY_SERVICE" 2>/dev/null || true
        warning "已无协议配置，Xray 已停止。"
    fi
}

install_xray(){
    run_script "$INSTALL_SCRIPT"
    pause
}

configure_vless(){
    run_script "$VLESS_SCRIPT"
    pause
}

configure_shadowsocks(){
    run_script "$SS_SCRIPT"
    pause
}

uninstall_vless(){
    header
    warning "正在卸载 VLESS Reality..."
    rm -f "${PROTOCOL_DIR}/vless.json" "${CLIENT_DIR}/vless.txt"
    rebuild_or_stop_xray
    pause
}

uninstall_shadowsocks(){
    header
    warning "正在卸载 Shadowsocks..."
    rm -f "${PROTOCOL_DIR}/shadowsocks.json" "${CLIENT_DIR}/shadowsocks.txt"
    rebuild_or_stop_xray
    pause
}

show_client_info(){
    header

    section "VLESS Reality" "$CYAN"
    echo
    if [[ -f "${CLIENT_DIR}/vless.txt" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "VLESS Link:" ]]; then
                label " VLESS Link (copy)"
                echo
                continue
            fi
            if [[ "$line" == "Mihomo / Clash:" ]]; then
                echo
                divider "$CYAN" "-"
                echo
                label " Mihomo / Clash Proxy Item (copy)"
                echo
                continue
            fi
            value "$line"
        done < "${CLIENT_DIR}/vless.txt"
    else
        warning "未配置"
    fi

    echo
    section "Shadowsocks" "$CYAN"
    echo
    if [[ -f "${CLIENT_DIR}/shadowsocks.txt" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "SS Link:" ]]; then
                label " Shadowsocks Link (copy)"
                echo
                continue
            fi
            if [[ "$line" == "Mihomo / Clash:" ]]; then
                echo
                divider "$CYAN" "-"
                echo
                label " Mihomo / Clash Proxy Item (copy)"
                echo
                continue
            fi
            value "$line"
        done < "${CLIENT_DIR}/shadowsocks.txt"
    else
        warning "未配置"
    fi

    pause
}

show_status(){
    header

    local status
    status=$(systemctl is-active "$XRAY_SERVICE" 2>/dev/null || echo "unknown")

    if [[ "$status" == "active" ]]; then
        success "Xray 状态: 运行中"
    else
        error "Xray 状态: ${status}"
    fi

    echo
    if command -v xray >/dev/null 2>&1; then
        label "版本"
        value "$(xray version | head -n1)"
    fi

    pause
}

restart_xray(){
    header
    info "正在重启 Xray..."

    systemctl restart "$XRAY_SERVICE"
    sleep 1

    if systemctl is-active --quiet "$XRAY_SERVICE"; then
        success "Xray 重启成功。"
    else
        error "Xray 重启失败。"
    fi

    pause
}

update_xray(){
    header
    warning "正在更新 Xray Core..."

    bash <(
        curl -fsSL -L \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh
    ) install

    echo
    if command -v xray >/dev/null 2>&1; then
        value "$(xray version | head -n1)"
    fi

    pause
}

run_vps_test(){
    header
    warning "即将运行 VPS 测试脚本。"

    if ! confirm_action "确认运行 VPS 测试脚本吗？"; then
        warning "已取消。"
        pause
        return
    fi

    apt update
    apt install wget curl -y
    bash <(curl -sL https://run.NodeQuality.com)
    exit 0
}

dd_debian(){
    header
    warning "即将 DD 安装 Debian，执行后系统可能重装并断开连接。"

    if ! confirm_action "确认 DD 安装 Debian 吗？"; then
        warning "已取消。"
        pause
        return
    fi

    apt update
    apt install wget curl -y
    curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
    bash reinstall.sh debian
    exit 0
}

show_ssh_status(){
    header

    local ssh_port
    local password_auth
    local pubkey_auth
    local root_login
    local service_status
    local key_status

    ssh_port=$(current_ssh_port)
    password_auth=$(awk 'tolower($1)=="passwordauthentication"{v=$2} END{print v ? v : "default"}' /etc/ssh/sshd_config)
    pubkey_auth=$(awk 'tolower($1)=="pubkeyauthentication"{v=$2} END{print v ? v : "default"}' /etc/ssh/sshd_config)
    root_login=$(awk 'tolower($1)=="permitrootlogin"{v=$2} END{print v ? v : "default"}' /etc/ssh/sshd_config)
    service_status=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "unknown")

    if [[ -s /root/.ssh/authorized_keys ]]; then
        key_status="已设置"
    else
        key_status="未设置"
    fi

    banner "     SSH 状态" "$GREEN"
    kv "SSH 端口              :" "$ssh_port"
    kv "SSH 服务              :" "$service_status"
    kv "Root 密钥             :" "$key_status"
    kv "密码登录              :" "$password_auth"
    kv "公钥登录              :" "$pubkey_auth"
    kv "Root 登录策略         :" "$root_login"

    pause
}

set_ssh_port(){
    header
    read -r -p "$(prompt_text "请输入新的 SSH 端口: ")" ssh_port

    if ! valid_port "$ssh_port"; then
        error "SSH 端口无效。"
        pause
        return
    fi

    local old_ssh_port
    old_ssh_port=$(current_ssh_port)

    if [[ "$ssh_port" != "$old_ssh_port" ]] && \
       ss -ltnH | awk '{print $4}' | grep -q ":${ssh_port}$"; then
        warning "端口可能已被占用，请确认后再试。"
        pause
        return
    fi

    info "正在设置 SSH 端口..."
    set_sshd_options "Port=${ssh_port}"

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${ssh_port}/tcp" comment "SSH" >/dev/null
        ufw delete allow 22/tcp >/dev/null 2>&1 || true
        ufw delete allow OpenSSH >/dev/null 2>&1 || true
    fi

    restart_ssh_service
    success "SSH 端口已设置为 ${ssh_port}，22 端口已从 UFW 规则中移除。"
    pause
}

set_ssh_key(){
    header
    read -r -p "$(prompt_text "请输入 SSH 公钥: ")" public_key

    if [[ -z "$public_key" ]]; then
        error "SSH 公钥不能为空。"
        pause
        return
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "$public_key" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    set_sshd_options \
        "PasswordAuthentication=no" \
        "PubkeyAuthentication=yes" \
        "PermitRootLogin=prohibit-password"

    restart_ssh_service
    success "SSH 密钥已设置，密码登录已关闭。"
    pause
}

ssh_menu(){
    while true; do
        header
        menu_item "1" "设置 SSH 端口"
        menu_item "2" "设置 SSH 密钥"
        menu_item "3" "查看 SSH 状态"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) set_ssh_port ;;
            2) set_ssh_key ;;
            3) show_ssh_status ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

install_ufw(){
    header
    ensure_apt_package "ufw"
    ufw --force enable >/dev/null
    success "UFW 已安装并启用。"
    pause
}

ufw_add_ip(){
    header
    read -r -p "$(prompt_text "请输入允许的 IP: ")" ip
    [[ -z "$ip" ]] && error "IP 不能为空。" && pause && return
    [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP。请使用“开放端口”。" && pause && return
    ufw allow from "$ip"
    success "已允许 IP: ${ip}"
    pause
}

ufw_delete_ip(){
    header
    read -r -p "$(prompt_text "请输入要删除的 IP: ")" ip
    [[ -z "$ip" ]] && error "IP 不能为空。" && pause && return
    [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP。请使用“删除端口”。" && pause && return
    ufw --force delete allow from "$ip" || true
    success "已删除 IP 规则: ${ip}"
    pause
}

ufw_add_port(){
    header
    read -r -p "$(prompt_text "请输入要开放的端口: ")" port
    [[ -z "$port" ]] && error "端口不能为空。" && pause && return
    valid_port "$port" || { error "端口无效。"; pause; return; }

    ufw allow "${port}/tcp"
    ufw allow "${port}/udp"
    success "已开放端口: ${port}/tcp 和 ${port}/udp"
    pause
}

ufw_delete_port(){
    header
    read -r -p "$(prompt_text "请输入要删除的端口: ")" port
    [[ -z "$port" ]] && error "端口不能为空。" && pause && return
    valid_port "$port" || { error "端口无效。"; pause; return; }

    ufw --force delete allow "${port}/tcp" || true
    ufw --force delete allow "${port}/udp" || true
    success "已删除端口规则: ${port}/tcp 和 ${port}/udp"
    pause
}

ufw_batch_add_port(){
    header
    local input
    local port

    read -r -p "$(prompt_text "请输入要允许的端口（多个用空格或逗号分隔）: ")" input
    [[ -z "$input" ]] && error "端口不能为空。" && pause && return

    for port in $(split_items "$input"); do
        valid_port "$port" || { error "端口无效: ${port}"; pause; return; }
    done

    for port in $(split_items "$input"); do
        ufw allow "${port}/tcp"
        ufw allow "${port}/udp"
        success "已允许端口: ${port}/tcp 和 ${port}/udp"
    done

    pause
}

ufw_batch_delete_port(){
    header
    local input
    local port

    read -r -p "$(prompt_text "请输入要删除的端口（多个用空格或逗号分隔）: ")" input
    [[ -z "$input" ]] && error "端口不能为空。" && pause && return

    for port in $(split_items "$input"); do
        valid_port "$port" || { error "端口无效: ${port}"; pause; return; }
    done

    for port in $(split_items "$input"); do
        ufw --force delete allow "${port}/tcp" || true
        ufw --force delete allow "${port}/udp" || true
        success "已删除端口规则: ${port}/tcp 和 ${port}/udp"
    done

    pause
}

ufw_batch_add_ip(){
    header
    local input
    local ip

    read -r -p "$(prompt_text "请输入要允许的 IP/CIDR（多个用空格或逗号分隔）: ")" input
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return

    for ip in $(split_items "$input"); do
        [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP: ${ip}" && pause && return
    done

    for ip in $(split_items "$input"); do
        ufw allow from "$ip"
        success "已允许 IP/CIDR: ${ip}"
    done

    pause
}

ufw_batch_delete_ip(){
    header
    local input
    local ip

    read -r -p "$(prompt_text "请输入要删除的 IP/CIDR（多个用空格或逗号分隔）: ")" input
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return

    for ip in $(split_items "$input"); do
        [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP: ${ip}" && pause && return
    done

    for ip in $(split_items "$input"); do
        ufw --force delete allow from "$ip" || true
        success "已删除 IP/CIDR 规则: ${ip}"
    done

    pause
}

restart_ufw(){
    header
    ufw --force reload
    success "UFW 已重启。"
    pause
}

show_ufw_status(){
    header

    if ! command -v ufw >/dev/null 2>&1; then
        warning "UFW 未安装。"
        pause
        return
    fi

    banner "     UFW 状态" "$GREEN"
    ufw status verbose
    pause
}

uninstall_ufw(){
    header
    warning "正在卸载 UFW..."
    ufw --force disable >/dev/null 2>&1 || true
    apt purge -y ufw
    apt autoremove -y
    success "UFW 已卸载。"
    pause
}

ufw_menu(){
    while true; do
        header
        menu_item "1" "安装 UFW"
        menu_item "2" "查看 UFW 状态"
        menu_item "3" "批量允许端口"
        menu_item "4" "批量删除端口"
        menu_item "5" "批量允许 IP"
        menu_item "6" "批量删除 IP"
        menu_item "7" "重启 UFW"
        menu_item "8" "卸载 UFW"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_ufw ;;
            2) show_ufw_status ;;
            3) ufw_batch_add_port ;;
            4) ufw_batch_delete_port ;;
            5) ufw_batch_add_ip ;;
            6) ufw_batch_delete_ip ;;
            7) restart_ufw ;;
            8) uninstall_ufw ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

install_fail2ban(){
    header
    ensure_apt_package "fail2ban"

    local ssh_port
    ssh_port=$(current_ssh_port)

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 604800
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
maxretry = 3
bantime = 604800
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    success "Fail2Ban 已安装并启动。"
    pause
}

show_fail2ban_status(){
    header
    fail2ban-client status sshd
    pause
}

uninstall_fail2ban(){
    header
    warning "正在卸载 Fail2Ban..."
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    apt purge -y fail2ban
    apt autoremove -y
    success "Fail2Ban 已卸载。"
    pause
}

fail2ban_menu(){
    while true; do
        header
        menu_item "1" "安装 Fail2Ban"
        menu_item "2" "查看 SSHD 状态"
        menu_item "3" "卸载 Fail2Ban"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_fail2ban ;;
            2) show_fail2ban_status ;;
            3) uninstall_fail2ban ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

install_swap(){
    header
    if [[ -n "$(swapon --show)" ]]; then
        warning "虚拟内存已存在。"
        pause
        return
    fi

    info "正在创建 1G 虚拟内存..."
    fallocate -l 1G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
    grep -q "^${SWAPFILE}" /etc/fstab || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
    success "虚拟内存已创建。"
    pause
}

delete_swap(){
    header
    warning "正在删除虚拟内存..."
    swapoff "$SWAPFILE" 2>/dev/null || true
    sed -i "\#^${SWAPFILE}#d" /etc/fstab
    rm -f "$SWAPFILE"
    success "虚拟内存已删除。"
    pause
}

show_swap_status(){
    header
    banner "     虚拟内存状态" "$GREEN"

    if [[ -n "$(swapon --show)" ]]; then
        swapon --show
    else
        warning "当前没有启用虚拟内存。"
    fi

    echo
    free -h
    pause
}

swap_menu(){
    while true; do
        header
        menu_item "1" "安装 1G 虚拟内存"
        menu_item "2" "查看虚拟内存状态"
        menu_item "3" "删除虚拟内存"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_swap ;;
            2) show_swap_status ;;
            3) delete_swap ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

set_timezone(){
    header
    timedatectl set-timezone "$TIMEZONE"
    success "时区已调整为 ${TIMEZONE}。"
    pause
}

configure_auto_updates(){
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
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
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
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=0
Persistent=true
EOF

    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

system_tuning(){
    header
    info "正在应用系统调优..."

    configure_auto_updates

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
    success "系统调优已完成。"

    echo
    banner "     调优后参数" "$GREEN"
    kv "default_qdisc                 :" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    kv "tcp_congestion_control        :" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    kv "nf_conntrack_max              :" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo unknown)"
    kv "somaxconn                     :" "$(sysctl -n net.core.somaxconn 2>/dev/null || echo unknown)"
    kv "rmem_max                      :" "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
    kv "wmem_max                      :" "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
    kv "tcp_fastopen                  :" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unknown)"
    kv "tcp_ecn                       :" "$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo unknown)"
    kv "tcp_mtu_probing               :" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unknown)"
    kv "swappiness                    :" "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
    kv "apt update timer              :" "03:00"
    kv "apt upgrade timer             :" "03:30"
    kv "auto reboot if needed         :" "04:00"

    pause
}

enable_ipv6(){
    header
    info "正在开启 IPv6..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    rm -f "$IPV6_SYSCTL_CONFIG"
    success "IPv6 已开启。"
    pause
}

disable_ipv6(){
    header
    warning "正在关闭 IPv6..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null

    cat > "$IPV6_SYSCTL_CONFIG" <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

    success "IPv6 已关闭。"
    pause
}

ipv6_menu(){
    while true; do
        header
        menu_item "1" "开启 IPv6"
        menu_item "2" "关闭 IPv6"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) enable_ipv6 ;;
            2) disable_ipv6 ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

tools_menu(){
    while true; do
        header
        menu_item "1" "VPS 测试"
        menu_item "2" "DD 系统 Debian"
        menu_item "3" "UFW 防火墙管理"
        menu_item "4" "Fail2Ban 管理"
        menu_item "5" "SSH 端口与密钥管理"
        menu_item "6" "虚拟内存管理"
        menu_item "7" "时区调整"
        menu_item "8" "系统调优"
        menu_item "9" "IPv6 管理"
        echo
        menu_item "0" "返回主菜单"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) run_vps_test ;;
            2) dd_debian ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) ssh_menu ;;
            6) swap_menu ;;
            7) set_timezone ;;
            8) system_tuning ;;
            9) ipv6_menu ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

main_menu(){
    while true; do
        header
        menu_item "1" "安装 Xray Core"
        menu_item "2" "配置 VLESS Reality"
        menu_item "3" "卸载 VLESS Reality"
        menu_item "4" "配置 Shadowsocks"
        menu_item "5" "卸载 Shadowsocks"
        echo
        divider "$CYAN" "-"
        echo
        menu_item "6" "查看节点信息"
        menu_item "7" "查看 Xray 状态"
        menu_item "8" "重启 Xray"
        menu_item "9" "更新 Xray Core"
        echo
        divider "$CYAN" "-"
        echo
        menu_item "66" "工具箱"
        echo
        divider "$CYAN" "-"
        echo
        menu_item "0" "退出"
        echo

        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_xray ;;
            2) configure_vless ;;
            3) uninstall_vless ;;
            4) configure_shadowsocks ;;
            5) uninstall_shadowsocks ;;
            6) show_client_info ;;
            7) show_status ;;
            8) restart_xray ;;
            9) update_xray ;;
            66) tools_menu ;;
            0) clear; exit 0 ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

main_menu
