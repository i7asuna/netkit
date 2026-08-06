#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

NETKIT_REPO_URL="https://github.com/i7asuna/netkit.git"
NETKIT_UPDATE_BRANCH="main"

update_netkit(){
    local current_commit target_commit dirty_state
    local current_short target_short
    local needs_confirmation=false

    header "更新工具箱"

    if ! require_commands git; then
        pause
        return
    fi

    if [[ ! -d "${SCRIPT_DIR}/.git" ]]; then
        error "当前目录不是 Git 安装，无法直接更新：${SCRIPT_DIR}"
        error "请重新运行一次安装命令完成 Git 安装。"
        pause
        return
    fi

    current_commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)
    current_short=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "未知")
    dirty_state=$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null || true)

    info "正在检查 GitHub 更新..."
    if git -C "$SCRIPT_DIR" remote get-url origin >/dev/null 2>&1; then
        if ! git -C "$SCRIPT_DIR" remote set-url origin "$NETKIT_REPO_URL"; then
            error "GitHub 远程地址设置失败。"
            pause
            return
        fi
    elif ! git -C "$SCRIPT_DIR" remote add origin "$NETKIT_REPO_URL"; then
        error "GitHub 远程地址添加失败。"
        pause
        return
    fi

    if ! git -C "$SCRIPT_DIR" fetch --prune origin; then
        error "更新检查失败，请检查 VPS 网络或 GitHub 连通性。"
        pause
        return
    fi

    target_commit=$(git -C "$SCRIPT_DIR" rev-parse "origin/${NETKIT_UPDATE_BRANCH}" 2>/dev/null || true)
    target_short=$(git -C "$SCRIPT_DIR" rev-parse --short "origin/${NETKIT_UPDATE_BRANCH}" 2>/dev/null || echo "未知")
    if [[ -z "$target_commit" ]]; then
        error "无法读取 GitHub 最新版本。"
        pause
        return
    fi

    if [[ "$current_commit" == "$target_commit" && -z "$dirty_state" ]]; then
        success "当前已是最新版本：$current_short"
        pause
        return
    fi

    if [[ -n "$dirty_state" ]]; then
        warning "检测到本地文件修改，继续更新将覆盖已跟踪文件的本地修改。"
        needs_confirmation=true
    fi
    if [[ -n "$current_commit" ]] && \
       ! git -C "$SCRIPT_DIR" merge-base --is-ancestor "$current_commit" "$target_commit"; then
        warning "本地提交与 GitHub 版本不一致，继续更新将以 GitHub main 为准。"
        needs_confirmation=true
    fi
    if $needs_confirmation && ! confirm_action "确认覆盖并更新吗？"; then
        warning "已取消更新。"
        pause
        return
    fi

    info "正在更新 NetKit：$current_short -> $target_short"
    if ! git -C "$SCRIPT_DIR" reset --hard "origin/${NETKIT_UPDATE_BRANCH}"; then
        error "工具箱更新失败。"
        pause
        return
    fi

    chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/core/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/system/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/config/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/lib/*.sh 2>/dev/null || true

    success "NetKit 已更新到 $target_short。"
    info "正在重新启动工具箱..."
    sleep 1
    if ! exec bash "${SCRIPT_DIR}/netkit.sh"; then
        error "工具箱重新启动失败，请手动执行 asuna。"
        pause
    fi
}

vps_test_menu(){
    while true; do
        header "服务器测试"
        menu_item "1" "IP 质量检测"
        menu_item "2" "TCP 质量检测"
        menu_item "3" "NextTrace 大小包追踪"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) run_ip_quality_test ;;
            2) run_tcp_quality_test ;;
            3) nexttrace_packet_menu ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

system_reinstall_kernel_menu(){
    while true; do
        header "系统重装与内核"
        menu_item "1" "DD 重装 Debian"
        menu_item "2" "安装 XanMod 内核（BBRv3）"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) dd_debian ;;
            2) install_xanmod_kernel ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

security_tools_menu(){
    while true; do
        header "安全防护"
        menu_item "1" "UFW 防火墙管理"
        menu_item "2" "Fail2Ban 管理"
        menu_item "3" "SSH 端口与密钥管理"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) ufw_menu ;;
            2) fail2ban_menu ;;
            3) ssh_menu ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

system_tools_menu(){
    while true; do
        header "系统维护"
        menu_item "1" "虚拟内存管理"
        menu_item "2" "时区调整"
        menu_item "3" "自动更新与自动重启"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) swap_menu ;;
            2) set_timezone ;;
            3) configure_auto_updates ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

network_tools_menu(){
    while true; do
        header "网络设置"
        menu_item "1" "TCP 调优（BBR / CUBIC）"
        menu_item "2" "IPv6 管理"
        menu_item "3" "MTU 设置"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) system_tuning ;;
            2) ipv6_menu ;;
            3) configure_mtu ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

tools_menu(){
    while true; do
        header "工具箱"
        menu_item "1" "更新工具箱"
        menu_item "2" "服务器测试（IP、TCP、路由追踪）"
        menu_item "3" "系统重装与内核（DD 重装、XanMod）"
        menu_item "4" "安全防护（UFW、Fail2Ban、SSH）"
        menu_item "5" "系统维护（虚拟内存、时区、自动更新）"
        menu_item "6" "网络设置（TCP、IPv6、MTU）"
        echo
        menu_item "0" "返回主菜单"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) update_netkit ;;
            2) vps_test_menu ;;
            3) system_reinstall_kernel_menu ;;
            4) security_tools_menu ;;
            5) system_tools_menu ;;
            6) network_tools_menu ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
