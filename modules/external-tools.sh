#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

IP_QUALITY_SCRIPT_URL="https://IP.Check.Place"
NEXTTRACE_INSTALLER_URL="https://nxtrace.org/nt"
NEXTTRACE_BIN_PATH="/usr/local/bin/nexttrace"
DEBIAN_REINSTALL_SCRIPT_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

run_ip_quality_test(){
    local temp_dir=""
    local status=0
    local report_generated=0

    header "IP 质量检测"
    ensure_apt_package curl

    if ! (
        temp_dir=$(mktemp -d) || exit 1
        trap '[[ -n "$temp_dir" ]] && rm -rf -- "$temp_dir"' EXIT
        curl -fsSL "$IP_QUALITY_SCRIPT_URL" -o "${temp_dir}/ip-quality.sh" || exit 1
        cd "$temp_dir" || exit 1

        if bash ./ip-quality.sh 2>&1 | tee ./ip-quality-output.log; then
            status=0
        else
            status=${PIPESTATUS[0]}
        fi

        if grep -Eq 'IP质量体检报告|IP QUALITY CHECK REPORT|感谢使用xy系列脚本|Thanks for running xy scripts' \
            ./ip-quality-output.log; then
            report_generated=1
        fi

        if (( status == 1 && report_generated == 1 )); then
            info "未检测到可用的 IPv6，已完成 IPv4 检测。"
        fi

        echo
        read -r -p "$(prompt_text "按 Enter 删除 IP 质量检测脚本...")"
        rm -rf -- "$temp_dir"
        temp_dir=""
        success "IP 质量检测脚本已删除。"

        if (( status != 0 && report_generated == 0 )); then
            exit "$status"
        fi
    ); then
        error "IP 质量检测未完成。"
        pause
    fi
}

install_nexttrace(){
    local temp_dir=""

    header "安装 NextTrace"
    if [[ -x "$NEXTTRACE_BIN_PATH" ]]; then
        warning "NextTrace 已安装。"
        path_kv "安装位置:" "$NEXTTRACE_BIN_PATH"
        "$NEXTTRACE_BIN_PATH" --version || true
        pause
        return
    fi

    ensure_apt_package curl
    info "正在安装 NextTrace..."

    if ! (
        temp_dir=$(mktemp -d) || exit 1
        trap 'rm -rf -- "$temp_dir"' EXIT
        curl -fsSL "$NEXTTRACE_INSTALLER_URL" -o "${temp_dir}/nexttrace-installer.sh" || exit 1
        cd "$temp_dir" || exit 1
        bash ./nexttrace-installer.sh --system
    ); then
        error "NextTrace 安装失败。"
        pause
        return
    fi

    hash -r
    if [[ ! -x "$NEXTTRACE_BIN_PATH" ]]; then
        error "NextTrace 已执行安装，但未找到 nexttrace 命令。"
        pause
        return
    fi

    success "NextTrace 安装完成。"
    path_kv "安装位置:" "$NEXTTRACE_BIN_PATH"
    pause
}

require_nexttrace(){
    if command -v nexttrace >/dev/null 2>&1; then
        return 0
    fi

    error "NextTrace 尚未安装，请先选择安装 NextTrace。"
    return 1
}

uninstall_nexttrace(){
    header "卸载 NextTrace"

    if [[ ! -e "$NEXTTRACE_BIN_PATH" ]]; then
        warning "未找到由 NetKit 安装的 NextTrace。"
        pause
        return
    fi

    if ! rm -f -- "$NEXTTRACE_BIN_PATH"; then
        error "NextTrace 卸载失败。"
        pause
        return
    fi

    hash -r
    success "NextTrace 已卸载。"
    pause
}
valid_nexttrace_packet_size(){
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 64 && 10#$1 <= 65535 ))
}

run_nexttrace_packet_trace(){
    local packet_size="$1"
    local target
    local status=0

    if ! require_nexttrace; then
        pause
        return
    fi

    header "NextTrace ${packet_size} 字节追踪"
    read -r -p "$(prompt_text "请输入目标 IP 或域名（输入 0 返回）: ")" target
    cancel_input "$target" && return

    if [[ -z "$target" ]]; then
        error "目标不能为空。"
        pause
        return
    fi

    nexttrace --psize "$packet_size" "$target" || status=$?
    if (( status != 0 )); then
        error "NextTrace 执行失败（退出码：${status}）。"
    fi
    pause
}

run_nexttrace_custom_packet_trace(){
    local packet_size

    header "NextTrace 自定义包大小"
    read -r -p "$(prompt_text "请输入包大小（64-65535 字节，输入 0 返回）: ")" packet_size
    cancel_input "$packet_size" && return

    if ! valid_nexttrace_packet_size "$packet_size"; then
        error "包大小必须是 64-65535 之间的整数。"
        pause
        return
    fi

    run_nexttrace_packet_trace "$packet_size"
}

nexttrace_packet_menu(){
    while true; do
        header "NextTrace 大小包追踪"
        menu_item "1" "安装 NextTrace"
        echo
        menu_item "2" "小包追踪（64 字节）"
        menu_item "3" "大包追踪（1400 字节）"
        menu_item "4" "自定义包大小"
        echo
        menu_item "5" "卸载 NextTrace"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) install_nexttrace ;;
            2) run_nexttrace_packet_trace 64 ;;
            3) run_nexttrace_packet_trace 1400 ;;
            4) run_nexttrace_custom_packet_trace ;;
            5) uninstall_nexttrace ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
dd_debian(){
    local temp_dir=""
    local status=0

    header "DD 重装 Debian"
    warning "即将运行 Debian 重装脚本，后续操作由脚本自身处理。"
    ensure_apt_package curl
    ensure_apt_package wget

    if (
        temp_dir=$(mktemp -d) || exit 1
        trap 'rm -rf -- "$temp_dir"' EXIT
        curl -fsSL "$DEBIAN_REINSTALL_SCRIPT_URL" -o "${temp_dir}/reinstall.sh" || exit 1
        cd "$temp_dir" || exit 1
        bash ./reinstall.sh debian
    ); then
        exit 0
    else
        status=$?
        error "Debian 重装脚本未完成（退出码：${status}）。"
        pause
    fi
}
