#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

require_sshd_environment(){
    if ! require_commands awk sed systemctl; then
        return 1
    fi

    if [[ ! -r /etc/ssh/sshd_config ]]; then
        error "未找到 SSHD 配置：/etc/ssh/sshd_config。"
        return 1
    fi

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
        systemctl restart ssh && return 0
    fi
    if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        systemctl restart sshd && return 0
    fi

    return 1
}

set_sshd_options(){
    local new_config=""
    local key

    for key in "$@"; do
        if ! sed -i "/^[#[:space:]]*${key%%=*}[[:space:]]/d" /etc/ssh/sshd_config; then
            return 1
        fi
        new_config+="${key%%=*} ${key#*=}"$'\n'
    done

    if ! awk -v CONFIG="$new_config" '
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
' /etc/ssh/sshd_config > /etc/ssh/sshd_config.tmp; then
        rm -f /etc/ssh/sshd_config.tmp
        return 1
    fi

    if ! mv /etc/ssh/sshd_config.tmp /etc/ssh/sshd_config; then
        rm -f /etc/ssh/sshd_config.tmp
        return 1
    fi
}

show_ssh_status(){
    header "SSH 状态"

    if ! require_sshd_environment; then
        pause
        return
    fi

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

    if ! require_sshd_environment || ! require_commands ss; then
        pause
        return
    fi

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
    if ! set_sshd_options "Port=${ssh_port}"; then
        error "SSHD 配置写入失败。"
        pause
        return
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ! ufw allow "${ssh_port}/tcp" comment "SSH" >/dev/null; then
            error "SSH 新端口的 UFW 规则添加失败，SSH 服务未重启。"
            pause
            return
        fi
        if [[ "$ssh_port" != "$old_ssh_port" ]]; then
            ufw delete allow "${old_ssh_port}/tcp" >/dev/null 2>&1 || true
            if [[ "$old_ssh_port" == "22" ]]; then
                ufw delete allow OpenSSH >/dev/null 2>&1 || true
            fi
        fi
    fi

    if ! restart_ssh_service; then
        error "SSH 服务重启失败，请检查 SSHD 配置和服务状态。"
        pause
        return
    fi

    success "SSH 端口已设置为 ${ssh_port}，防火墙规则已更新。"
    pause
}

set_ssh_key(){
    header "设置 SSH 密钥"

    if ! require_sshd_environment; then
        pause
        return
    fi

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

    if ! set_sshd_options \
        "PasswordAuthentication=no" \
        "PubkeyAuthentication=yes" \
        "PermitRootLogin=prohibit-password"; then
        error "SSHD 配置写入失败。"
        pause
        return
    fi

    if ! restart_ssh_service; then
        error "SSH 服务重启失败，请检查 SSHD 配置和服务状态。"
        pause
        return
    fi

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
