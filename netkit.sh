#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_INSTALL_SCRIPT="${SCRIPT_DIR}/core/mihomo-core.sh"
MIHOMO_VLESS_SCRIPT="${SCRIPT_DIR}/core/mihomo-vless-reality.sh"
MIHOMO_SS_SCRIPT="${SCRIPT_DIR}/core/mihomo-shadowsocks.sh"
MIHOMO_BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
XANMOD_SCRIPT="${SCRIPT_DIR}/system/xanmod-kernel.sh"

MIHOMO_SERVICE="mihomo"
MIHOMO_DIR="/etc/mihomo"
MIHOMO_PROTOCOL_DIR="${MIHOMO_DIR}/protocols"
MIHOMO_CLIENT_DIR="${MIHOMO_DIR}/client"
IPV6_SYSCTL_CONFIG="/etc/sysctl.d/99-netkit-ipv6.conf"
SYSCTL_CONFIG="/etc/sysctl.d/99-z-bbr.conf"
SWAPFILE="/swapfile"
TIMEZONE="Asia/Hong_Kong"
NETWORK_INTERFACES_CONFIG="/etc/network/interfaces"
XANMOD_APT_SOURCE="/etc/apt/sources.list.d/xanmod-release.list"
XANMOD_UNATTENDED_CONFIG="/etc/apt/apt.conf.d/52unattended-upgrades-xanmod"
MTU_VALUE=1500

header(){
    local title="${1:-NetKit}"

    echo
    divider "$CYAN"
    center_line "$title" "$WHITE"
    divider "$CYAN"
}

run_script(){
    local file="$1"
    shift

    if [[ ! -f "$file" ]]; then
        error "脚本不存在: $file"
        pause
        return 1
    fi

    bash "$file" "$@"
}

run_script_and_pause(){
    local status=0

    run_script "$@" || status=$?
    [[ "$status" -eq "$INPUT_CANCEL_STATUS" ]] && return 0
    pause
}

SELECTED_VERSION=""

select_mihomo_version(){
    local input
    local release_json

    SELECTED_VERSION=""

    echo
    read -r -p "$(prompt_text "请输入 Mihomo 正式稳定版版本号（回车使用最新稳定版，输入 0 取消）: ")" input
    input=$(trim_edges "$input")

    cancel_input "$input" && return "$INPUT_CANCEL_STATUS"

    if [[ -z "$input" ]]; then
        return 0
    fi

    input="v${input#v}"

    if [[ ! "$input" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "版本号格式无效：${input}"
        error "仅支持正式稳定版版本号。"
        return 1
    fi

    info "正在验证 Mihomo ${input}..."

    if ! release_json=$(curl -fsSL -L \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/${input}"); then
        error "未找到 Mihomo ${input}，请检查版本号。"
        return 1
    fi

    if ! grep -q '"prerelease":[[:space:]]*false' <<< "$release_json" || \
       ! grep -q '"draft":[[:space:]]*false' <<< "$release_json"; then
        error "Mihomo ${input} 不是正式稳定版，已拒绝安装。"
        return 1
    fi

    SELECTED_VERSION="$input"
}

valid_port(){
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

split_items(){
    local input="$1"
    printf '%s\n' $input
}

reject_comma_separator(){
    [[ "$1" == *","* ]] && error "请使用空格分隔，不要使用逗号。" && pause && return 1
    return 0
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

rebuild_or_stop_mihomo(){
    local found=false
    local file

    for file in "$MIHOMO_PROTOCOL_DIR"/*.yaml; do
        if [[ -f "$file" ]]; then
            found=true
            break
        fi
    done

    if $found; then
        bash "$MIHOMO_BUILD_CONFIG_SCRIPT"
        systemctl restart "$MIHOMO_SERVICE"
        success "Mihomo 配置已重建并重启。"
    else
        rm -f "${MIHOMO_DIR}/config.yaml"
        systemctl stop "$MIHOMO_SERVICE" 2>/dev/null || true
        warning "已无协议配置，Mihomo 已停止。"
    fi
}

show_client_info(){
    header "连接信息"

    section "Mihomo" "$GREEN"
    echo
    section "VLESS + TCP + XTLS Vision + REALITY" "$YELLOW"
    echo
    if [[ -f "${MIHOMO_CLIENT_DIR}/vless.txt" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "VLESS Link:" ]]; then
                label " VLESS Link"
                echo
                continue
            fi
            if [[ "$line" == "Mihomo / Clash:" ]]; then
                echo
                divider "$CYAN" "-"
                echo
                label " Mihomo / Clash YAML"
                echo
                continue
            fi
            value "$line"
        done < "${MIHOMO_CLIENT_DIR}/vless.txt"
    else
        warning "未配置"
    fi

    echo
    section "Shadowsocks" "$YELLOW"
    echo
    if [[ -f "${MIHOMO_CLIENT_DIR}/shadowsocks.txt" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == "SS Link:" ]]; then
                label " Shadowsocks Link"
                echo
                continue
            fi
            if [[ "$line" == "Mihomo / Clash:" ]]; then
                echo
                divider "$CYAN" "-"
                echo
                label " Mihomo / Clash YAML"
                echo
                continue
            fi
            value "$line"
        done < "${MIHOMO_CLIENT_DIR}/shadowsocks.txt"
    else
        warning "未配置"
    fi

    pause
}
install_mihomo(){
    local selection_status=0

    header "安装 / 更新 Mihomo"
    select_mihomo_version || selection_status=$?
    [[ "$selection_status" -eq "$INPUT_CANCEL_STATUS" ]] && return
    if [[ "$selection_status" -ne 0 ]]; then
        pause
        return
    fi

    if [[ -n "$SELECTED_VERSION" ]]; then
        warning "正在安装 Mihomo ${SELECTED_VERSION}..."
    else
        warning "正在安装 Mihomo 最新正式稳定版..."
    fi

    run_script "$MIHOMO_INSTALL_SCRIPT" "$SELECTED_VERSION"
    pause
}

configure_mihomo_vless(){
    run_script_and_pause "$MIHOMO_VLESS_SCRIPT"
}

configure_mihomo_shadowsocks(){
    run_script_and_pause "$MIHOMO_SS_SCRIPT"
}

uninstall_mihomo_vless(){
    local port

    header "卸载 Mihomo VLESS + TCP + XTLS Vision + REALITY"
    warning "正在卸载 Mihomo VLESS + TCP + XTLS Vision + REALITY..."
    port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/vless.yaml" "port")
    rm -f "${MIHOMO_PROTOCOL_DIR}/vless.yaml" "${MIHOMO_CLIENT_DIR}/vless.txt"
    rebuild_or_stop_mihomo
    remove_ufw_port_rule "$port" tcp
    remove_ufw_port_rule "$port" udp
    pause
}

uninstall_mihomo_shadowsocks(){
    local port

    header "卸载 Mihomo Shadowsocks"
    warning "正在卸载 Mihomo Shadowsocks..."
    port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/shadowsocks.yaml" "port")
    rm -f "${MIHOMO_PROTOCOL_DIR}/shadowsocks.yaml" "${MIHOMO_CLIENT_DIR}/shadowsocks.txt"
    rebuild_or_stop_mihomo
    remove_ufw_port_rule "$port" tcp
    remove_ufw_port_rule "$port" udp
    pause
}

show_mihomo_logs(){
    header "Mihomo 日志"

    if ! command -v journalctl >/dev/null 2>&1; then
        error "当前系统不支持 journalctl，无法查看 Mihomo 日志。"
        pause
        return
    fi

    if ! command -v mihomo >/dev/null 2>&1; then
        warning "未检测到 Mihomo，以下可能没有可用日志。"
        echo
    fi

    section "最近 100 条日志" "$YELLOW"
    echo
    if ! journalctl -u "$MIHOMO_SERVICE" -n 100 --no-pager; then
        error "Mihomo 日志读取失败。"
    fi

    pause
}

show_mihomo_core(){
    header "Mihomo 核心"

    local status
    status=$(systemctl is-active "$MIHOMO_SERVICE" 2>/dev/null || true)
    status=${status:-unknown}

    if [[ "$status" == "active" ]]; then
        success "Mihomo 状态: 运行中"
    else
        warning "Mihomo 状态: ${status}"
    fi

    echo
    if command -v mihomo >/dev/null 2>&1; then
        label "版本"
        value "$(mihomo -v | head -n1)"
    else
        warning "未检测到 Mihomo。"
    fi

    echo
    section "协议配置" "$YELLOW"
    echo
    if [[ -f "${MIHOMO_CLIENT_DIR}/vless.txt" ]]; then
        kv "VLESS + TCP + XTLS Vision + REALITY    :" "已配置（UDP 已开启）"
    else
        kv "VLESS + TCP + XTLS Vision + REALITY    :" "未配置"
    fi

    if [[ -f "${MIHOMO_CLIENT_DIR}/shadowsocks.txt" ]]; then
        kv "Shadowsocks      :" "已配置（UDP 已开启）"
    else
        kv "Shadowsocks      :" "未配置"
    fi

    pause
}

restart_mihomo(){
    header "重启 Mihomo"

    if ! command -v mihomo >/dev/null 2>&1; then
        error "未检测到 Mihomo，请先安装。"
        pause
        return
    fi

    info "正在重启 Mihomo..."
    if ! systemctl restart "$MIHOMO_SERVICE"; then
        error "Mihomo 重启失败。"
        pause
        return
    fi

    sleep 1
    if systemctl is-active --quiet "$MIHOMO_SERVICE"; then
        success "Mihomo 重启成功。"
    else
        error "Mihomo 重启失败。"
    fi

    pause
}

uninstall_mihomo(){
    local vless_port shadowsocks_port

    header "卸载 Mihomo"
    warning "即将卸载 Mihomo，并删除其配置和连接信息。"

    if ! confirm_action "确认卸载 Mihomo 吗？"; then
        warning "已取消。"
        pause
        return
    fi

    vless_port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/vless.yaml" "port")
    shadowsocks_port=$(yaml_number_field "${MIHOMO_PROTOCOL_DIR}/shadowsocks.yaml" "port")

    systemctl disable --now "$MIHOMO_SERVICE" 2>/dev/null || true
    remove_ufw_port_rule "$vless_port" tcp
    remove_ufw_port_rule "$vless_port" udp
    remove_ufw_port_rule "$shadowsocks_port" tcp
    remove_ufw_port_rule "$shadowsocks_port" udp

    rm -f /usr/local/bin/mihomo /etc/systemd/system/mihomo.service
    rm -rf "$MIHOMO_DIR"
    systemctl daemon-reload

    if command -v mihomo >/dev/null 2>&1; then
        warning "Mihomo 程序仍然存在，请检查是否由其他方式安装。"
    else
        success "Mihomo 与其配置已卸载。"
    fi

    pause
}

run_vps_test(){
    header "VPS 测试"
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
    header "DD 系统 Debian"
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

install_xanmod_kernel(){
    if ! run_script "$XANMOD_SCRIPT"; then
        error "XanMod 内核安装未完成。"
    fi
    pause
}

show_ssh_status(){
    header "SSH 状态"

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

    kv "SSH 端口              :" "$ssh_port"
    kv "SSH 服务              :" "$service_status"
    kv "Root 密钥             :" "$key_status"
    kv "密码登录              :" "$password_auth"
    kv "公钥登录              :" "$pubkey_auth"
    kv "Root 登录策略         :" "$root_login"

    pause
}

set_ssh_port(){
    header "设置 SSH 端口"
    read -r -p "$(prompt_text "请输入新的 SSH 端口（输入 0 取消）: ")" ssh_port
    cancel_input "$ssh_port" && return

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
        if [[ "$ssh_port" != "$old_ssh_port" ]]; then
            ufw delete allow "${old_ssh_port}/tcp" >/dev/null 2>&1 || true
            if [[ "$old_ssh_port" == "22" ]]; then
                ufw delete allow OpenSSH >/dev/null 2>&1 || true
            fi
        fi
    fi

    restart_ssh_service
    success "SSH 端口已设置为 ${ssh_port}，防火墙规则已更新。"
    pause
}

set_ssh_key(){
    header "设置 SSH 密钥"
    read -r -p "$(prompt_text "请输入 SSH 公钥（输入 0 取消）: ")" public_key
    cancel_input "$public_key" && return

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
        header "SSH 端口与密钥管理"
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
    header "安装 UFW"
    ensure_apt_package "ufw"
    ufw --force enable >/dev/null
    success "UFW 已安装并启用。"
    pause
}

ufw_add_ip(){
    header "允许 IP"
    read -r -p "$(prompt_text "请输入允许的 IP（输入 0 取消）: ")" ip
    cancel_input "$ip" && return
    [[ -z "$ip" ]] && error "IP 不能为空。" && pause && return
    [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP。请使用“允许端口”。" && pause && return
    ufw allow from "$ip"
    success "已允许 IP: ${ip}"
    pause
}

ufw_delete_ip(){
    header "删除 IP"
    read -r -p "$(prompt_text "请输入要删除的 IP（输入 0 取消）: ")" ip
    cancel_input "$ip" && return
    [[ -z "$ip" ]] && error "IP 不能为空。" && pause && return
    [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP。请使用“删除端口”。" && pause && return
    ufw --force delete allow from "$ip" || true
    success "已删除 IP 规则: ${ip}"
    pause
}

ufw_add_port(){
    header "允许端口"
    read -r -p "$(prompt_text "请输入要允许的端口（输入 0 取消）: ")" port
    cancel_input "$port" && return
    [[ -z "$port" ]] && error "端口不能为空。" && pause && return
    valid_port "$port" || { error "端口无效。"; pause; return; }

    ufw allow "${port}/tcp"
    ufw allow "${port}/udp"
    success "已允许端口: ${port}/tcp 和 ${port}/udp"
    pause
}

ufw_delete_port(){
    header "删除端口"
    read -r -p "$(prompt_text "请输入要删除的端口（输入 0 取消）: ")" port
    cancel_input "$port" && return
    [[ -z "$port" ]] && error "端口不能为空。" && pause && return
    valid_port "$port" || { error "端口无效。"; pause; return; }

    ufw --force delete allow "${port}/tcp" || true
    ufw --force delete allow "${port}/udp" || true
    success "已删除端口规则: ${port}/tcp 和 ${port}/udp"
    pause
}

ufw_batch_add_port(){
    header "允许端口"
    local input
    local port

    read -r -p "$(prompt_text "请输入要允许的端口（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "端口不能为空。" && pause && return
    reject_comma_separator "$input" || return

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
    header "删除端口"

    local input
    local status_output
    local index
    local display_index
    local record
    local line
    local rule_number
    local port
    local record_port
    local protocol
    local comment
    local descriptor
    local details
    local -A seen_details=()
    local -a rule_records=()
    local -a ports=()
    local -a requested_indexes=()
    local -a delete_rule_numbers=()
    local -A selected_indexes=()
    local -A selected_ports=()

    if ! command -v ufw >/dev/null 2>&1; then
        warning "UFW 未安装。"
        pause
        return
    fi

    if ! status_output=$(ufw status numbered); then
        error "无法读取 UFW 端口规则。"
        pause
        return
    fi

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+)(/(tcp|udp))?([[:space:]]|$) ]]; then
            rule_number="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            protocol="${BASH_REMATCH[4]:-all}"
            comment=""
            [[ "$line" == *"#"* ]] && comment=$(trim_edges "${line#*#}")
            rule_records+=("${rule_number}|${port}|${protocol}|${comment}")
        fi
    done <<< "$status_output"

    if [[ "${#rule_records[@]}" -eq 0 ]]; then
        warning "当前没有可删除的数字端口规则。"
        pause
        return
    fi

    mapfile -t ports < <(
        printf '%s\n' "${rule_records[@]}" | cut -d '|' -f2 | sort -n -u
    )

    section "当前 UFW 端口" "$YELLOW"
    echo
    label " 端口 / 协议 / 注释"
    echo
    for index in "${!ports[@]}"; do
        port="${ports[$index]}"
        details=""
        seen_details=()

        for record in "${rule_records[@]}"; do
            IFS='|' read -r rule_number record_port protocol comment <<< "$record"
            [[ "$record_port" == "$port" ]] || continue

            descriptor="$protocol"
            [[ -n "$comment" ]] && descriptor+=" · ${comment}"
            if [[ -z "${seen_details[$descriptor]:-}" ]]; then
                seen_details["$descriptor"]=1
                details+="${details:+; }${descriptor}"
            fi
        done

        menu_item "$((index + 1))" "${port}  ${details}"
    done

    echo
    read -r -p "$(prompt_text "请输入要删除的序号（多个用空格分隔，0 取消）: ")" input
    input=$(trim_edges "$input")
    cancel_input "$input" && return

    if [[ -z "$input" ]]; then
        error "序号不能为空。"
        pause
        return
    fi

    read -r -a requested_indexes <<< "$input"

    for display_index in "${requested_indexes[@]}"; do
        if [[ ! "$display_index" =~ ^[0-9]+$ ]] || \
           (( display_index < 1 || display_index > ${#ports[@]} )); then
            error "无效序号：${display_index}。多个序号请使用空格分隔。"
            pause
            return
        fi

        selected_indexes["$display_index"]=1
        selected_ports["${ports[$((display_index - 1))]}"]=1
    done

    for record in "${rule_records[@]}"; do
        IFS='|' read -r rule_number record_port protocol comment <<< "$record"
        if [[ -n "${selected_ports[$record_port]:-}" ]]; then
            delete_rule_numbers+=("$rule_number")
        fi
    done

    mapfile -t delete_rule_numbers < <(
        printf '%s\n' "${delete_rule_numbers[@]}" | sort -rn -u
    )

    for rule_number in "${delete_rule_numbers[@]}"; do
        ufw --force delete "$rule_number" >/dev/null
    done

    for display_index in $(printf '%s\n' "${!selected_indexes[@]}" | sort -n); do
        port="${ports[$((display_index - 1))]}"
        success "已删除端口 ${port} 的 UFW 规则。"
    done

    pause
}

ufw_batch_add_ip(){
    header "允许 IP"
    local input
    local ip

    read -r -p "$(prompt_text "请输入要允许的 IP/CIDR（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return
    reject_comma_separator "$input" || return

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
    header "删除 IP"
    local input
    local ip

    read -r -p "$(prompt_text "请输入要删除的 IP/CIDR（多个用空格分隔，输入 0 取消）: ")" input
    cancel_input "$input" && return
    [[ -z "$input" ]] && error "IP 不能为空。" && pause && return
    reject_comma_separator "$input" || return

    for ip in $(split_items "$input"); do
        [[ "$ip" =~ ^[0-9]+$ ]] && error "这是端口，不是 IP: ${ip}" && pause && return
    done

    for ip in $(split_items "$input"); do
        ufw --force delete allow from "$ip" || true
        success "已删除 IP/CIDR 规则: ${ip}"
    done

    pause
}

show_ufw_status(){
    header "UFW 状态"

    if ! command -v ufw >/dev/null 2>&1; then
        warning "UFW 未安装。"
        pause
        return
    fi

    ufw status verbose
    pause
}

uninstall_ufw(){
    header "卸载 UFW"
    warning "正在卸载 UFW..."
    ufw --force disable >/dev/null 2>&1 || true
    apt purge -y ufw
    apt autoremove -y
    success "UFW 已卸载。"
    pause
}

ufw_menu(){
    while true; do
        header "UFW 防火墙管理"
        menu_item "1" "安装 UFW"
        menu_item "2" "查看 UFW 状态"
        menu_item "3" "允许端口"
        menu_item "4" "删除端口"
        menu_item "5" "允许 IP"
        menu_item "6" "删除 IP"
        menu_item "7" "卸载 UFW"
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
            7) uninstall_ufw ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

install_fail2ban(){
    header "安装 Fail2Ban"
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
    header "SSHD 状态"
    fail2ban-client status sshd
    pause
}

uninstall_fail2ban(){
    header "卸载 Fail2Ban"
    warning "正在卸载 Fail2Ban..."
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    apt purge -y fail2ban
    apt autoremove -y
    success "Fail2Ban 已卸载。"
    pause
}

fail2ban_unban_ip(){
    header "解封 SSHD IP"
    local ip

    read -r -p "$(prompt_text "请输入要解封的 IP（输入 0 取消）: ")" ip
    cancel_input "$ip" && return

    if [[ -z "$ip" ]]; then
        error "IP 不能为空。"
        pause
        return
    fi

    fail2ban-client set sshd unbanip "$ip"
    success "已从 sshd jail 解封 IP: ${ip}"
    pause
}

fail2ban_menu(){
    while true; do
        header "Fail2Ban 管理"
        menu_item "1" "安装 Fail2Ban"
        menu_item "2" "查看 SSHD 状态"
        menu_item "3" "解封 SSHD IP"
        menu_item "4" "卸载 Fail2Ban"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_fail2ban ;;
            2) show_fail2ban_status ;;
            3) fail2ban_unban_ip ;;
            4) uninstall_fail2ban ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

install_swap(){
    header "安装虚拟内存"
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
    header "删除虚拟内存"
    warning "正在删除虚拟内存..."
    swapoff "$SWAPFILE" 2>/dev/null || true
    sed -i "\#^${SWAPFILE}#d" /etc/fstab
    rm -f "$SWAPFILE"
    success "虚拟内存已删除。"
    pause
}

show_swap_status(){
    header "虚拟内存状态"

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
        header "虚拟内存管理"
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

system_tuning(){
    local congestion_control=""
    local choice

    while [[ -z "$congestion_control" ]]; do
        header "系统调优"
        section "请选择 TCP 拥塞控制算法" "$YELLOW"
        menu_item "1" "BBR"
        menu_item "2" "CUBIC"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) congestion_control="bbr" ;;
            2) congestion_control="cubic" ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done

    header "系统调优"
    info "正在应用系统调优（${congestion_control^^}）..."

    modprobe nf_conntrack 2>/dev/null || true
    modprobe "tcp_${congestion_control}" 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "$congestion_control"; then
        error "当前内核不支持 ${congestion_control^^}，无法应用系统调优。"
        pause
        return
    fi

    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

    cat > "$SYSCTL_CONFIG" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${congestion_control}

net.netfilter.nf_conntrack_max = 32768
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

net.core.rmem_max = 4194304
net.core.wmem_max = 4194304

net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_mtu_probing = 1

vm.swappiness = 10
EOF

    sysctl --system >/dev/null
    success "系统调优已完成。"

    echo
    section "调优后参数" "$YELLOW"
    kv "default_qdisc                 :" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    kv "tcp_congestion_control        :" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    kv "nf_conntrack_max              :" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo unknown)"
    kv "nf_conntrack_udp_timeout      :" "$(sysctl -n net.netfilter.nf_conntrack_udp_timeout 2>/dev/null || echo unknown)"
    kv "nf_conntrack_udp_stream       :" "$(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream 2>/dev/null || echo unknown)"
    kv "nf_conntrack_tcp_established  :" "$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo unknown)"
    kv "rmem_max                      :" "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
    kv "wmem_max                      :" "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
    kv "tcp_fastopen                  :" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unknown)"
    kv "tcp_ecn                       :" "$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo unknown)"
    kv "tcp_mtu_probing               :" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unknown)"
    kv "swappiness                    :" "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
    pause
}

detect_default_interface(){
    ip route | awk '
        $1 == "default" {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

current_interface_mtu(){
    local interface="$1"

    ip -o link show dev "$interface" | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "mtu") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

is_debian(){
    [[ -r /etc/os-release ]] || return 1

    local os_id=""
    # shellcheck source=/dev/null
    source /etc/os-release
    os_id="${ID:-}"
    [[ "$os_id" == "debian" ]]
}

validate_mtu_value(){
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 576 ]] && [[ "$1" -le 9000 ]]
}

is_ifupdown_network(){
    dpkg -s ifupdown >/dev/null 2>&1
}

list_interfaces_config_files(){
    local pattern
    local file

    [[ -f "$NETWORK_INTERFACES_CONFIG" ]] && printf '%s\n' "$NETWORK_INTERFACES_CONFIG"

    if [[ -f "$NETWORK_INTERFACES_CONFIG" ]]; then
        while IFS= read -r pattern; do
            for file in $pattern; do
                [[ -f "$file" ]] && printf '%s\n' "$file"
            done
        done < <(awk '
            /^[[:space:]]*source[[:space:]]+/ || /^[[:space:]]*source-directory[[:space:]]+/ {
                print $2
            }
        ' "$NETWORK_INTERFACES_CONFIG")
    fi

    if [[ -d /etc/network/interfaces.d ]]; then
        find /etc/network/interfaces.d -maxdepth 1 -type f 2>/dev/null | sort
    fi
}

find_interface_config_file(){
    local interface="$1"
    local file

    while IFS= read -r file; do
        awk -v iface="$interface" '
            $1 == "iface" && $2 == iface && $3 == "inet" {
                found = 1
            }
            END {
                exit found ? 0 : 1
            }
        ' "$file" && {
            printf '%s\n' "$file"
            return 0
        }
    done < <(list_interfaces_config_files | awk '!seen[$0]++')

    return 1
}

update_interfaces_mtu(){
    local interface="$1"
    local mtu="$2"
    local config_file="$3"
    local tmp_file

    tmp_file=$(mktemp)

    if ! awk -v iface="$interface" -v mtu="$mtu" '
function write_mtu() {
    if (in_target && !mtu_written) {
        print "    mtu " mtu
        mtu_written = 1
    }
}

/^[[:space:]]*iface[[:space:]]+/ {
    write_mtu()
    in_target = 0
    mtu_written = 0

    if ($2 == iface && $3 == "inet") {
        found = 1
        in_target = 1
    }

    print
    next
}

in_target && /^[[:space:]]*mtu[[:space:]]+/ {
    if (!mtu_written) {
        print "    mtu " mtu
        mtu_written = 1
    }
    next
}

{
    print
}

END {
    write_mtu()
    if (!found) {
        exit 2
    }
}
' "$config_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if ! mv "$tmp_file" "$config_file"; then
        rm -f "$tmp_file"
        return 1
    fi
}

configure_mtu(){
    while true; do
        header "MTU 设置"

        if ! is_debian; then
            error "MTU 设置仅支持 Debian + ifupdown。"
            pause
            return
        fi

        if ! is_ifupdown_network; then
            error "MTU 设置仅支持 Debian + ifupdown。"
            pause
            return
        fi

        if [[ ! -f "$NETWORK_INTERFACES_CONFIG" ]]; then
            error "ifupdown config not found: ${NETWORK_INTERFACES_CONFIG}"
            pause
            return
        fi

        local interface
        local current_mtu
        local new_mtu
        local config_file

        interface=$(detect_default_interface)

        if [[ -z "$interface" ]]; then
            error "Failed to detect default network interface from ip route."
            pause
            return
        fi

        current_mtu=$(current_interface_mtu "$interface")
        current_mtu=${current_mtu:-unknown}

        echo
        label "Current Interface:"
        value "$interface"
        echo
        label "Current MTU:"
        value "$current_mtu"
        echo
        read -r -p "$(prompt_text "Enter MTU [default: ${MTU_VALUE}, 0 to cancel]: ")" new_mtu
        cancel_input "$new_mtu" && return
        new_mtu=${new_mtu:-$MTU_VALUE}

        if ! validate_mtu_value "$new_mtu"; then
            error "Invalid MTU value. Use a number between 576 and 9000."
            pause
            continue
        fi

        if ! config_file=$(find_interface_config_file "$interface"); then
            error "iface ${interface} inet not found in /etc/network/interfaces or /etc/network/interfaces.d/."
            pause
            return
        fi

        info "Updating ${config_file}..."

        if ! update_interfaces_mtu "$interface" "$new_mtu" "$config_file"; then
            error "Failed to update ${config_file}."
            pause
            return
        fi

        info "Applying MTU immediately..."

        if ! ip link set dev "$interface" mtu "$new_mtu"; then
            error "Failed to apply MTU ${new_mtu} to ${interface}."
            pause
            return
        fi

        success "MTU updated."
        echo
        label "Interface:"
        value "$interface"
        echo
        label "MTU:"
        value "$new_mtu"
        echo
        ip link show "$interface"
        pause
        return
    done
}
enable_ipv6(){
    header "开启 IPv6"
    info "正在开启 IPv6..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    rm -f "$IPV6_SYSCTL_CONFIG"
    success "IPv6 已开启。"
    pause
}

disable_ipv6(){
    header "关闭 IPv6"
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
        header "IPv6 管理"
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
        header "工具箱"
        menu_item "1" "VPS 测试"
        menu_item "2" "DD 系统 Debian"
        menu_item "3" "安装 XanMod 内核（BBRv3）"
        menu_item "4" "UFW 防火墙管理"
        menu_item "5" "Fail2Ban 管理"
        menu_item "6" "SSH 端口与密钥管理"
        menu_item "7" "虚拟内存管理"
        menu_item "8" "时区调整"
        menu_item "9" "系统调优"
        menu_item "10" "IPv6 管理"
        menu_item "11" "MTU 设置"
        menu_item "12" "自动更新与自动重启"
        echo
        menu_item "0" "返回主菜单"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) run_vps_test ;;
            2) dd_debian ;;
            3) install_xanmod_kernel ;;
            4) ufw_menu ;;
            5) fail2ban_menu ;;
            6) ssh_menu ;;
            7) swap_menu ;;
            8) set_timezone ;;
            9) system_tuning ;;
            10) ipv6_menu ;;
            11) configure_mtu ;;
            12) configure_auto_updates ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

mihomo_menu(){
    while true; do
        header "Mihomo"
        menu_item "1" "安装 / 更新 Mihomo"
        menu_item "2" "查看 Mihomo 核心"
        menu_item "3" "查看 Mihomo 日志"
        menu_item "4" "安装 VLESS + TCP + XTLS Vision + REALITY"
        menu_item "5" "卸载 VLESS + TCP + XTLS Vision + REALITY"
        menu_item "6" "安装 Shadowsocks"
        menu_item "7" "卸载 Shadowsocks"
        menu_item "8" "重启 Mihomo"
        menu_item "9" "卸载 Mihomo"
        echo
        menu_item "0" "返回主菜单"
        echo

        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_mihomo ;;
            2) show_mihomo_core ;;
            3) show_mihomo_logs ;;
            4) configure_mihomo_vless ;;
            5) uninstall_mihomo_vless ;;
            6) configure_mihomo_shadowsocks ;;
            7) uninstall_mihomo_shadowsocks ;;
            8) restart_mihomo ;;
            9) uninstall_mihomo ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

main_menu(){
    while true; do
        header
        section "核心入口" "$YELLOW"
        echo
        menu_item "1" "Mihomo"
        echo
        section "连接信息" "$YELLOW"
        echo
        menu_item "11" "查看连接信息"
        echo
        section "工具" "$YELLOW"
        echo
        menu_item "66" "工具箱"
        echo
        menu_item "0" "退出"
        echo

        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) mihomo_menu ;;
            11) show_client_info ;;
            66) tools_menu ;;
            0) exit 0 ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

main_menu