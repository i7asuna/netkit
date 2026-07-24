#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

test_and_reinstall_menu(){
    while true; do
        header "IP 检测 / 路由追踪 / Debian 重装"
        menu_item "1" "IP 质量检测"
        menu_item "2" "NextTrace 大小包追踪"
        echo
        menu_item "9" "DD 重装 Debian"
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) run_ip_quality_test ;;
            2) nexttrace_packet_menu ;;
            9) dd_debian ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

security_tools_menu(){
    while true; do
        header "SSH 与安全防护"
        menu_item "1" "SSH 端口与密钥管理"
        menu_item "2" "UFW 防火墙管理"
        menu_item "3" "Fail2Ban 管理"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) ssh_menu ;;
            2) ufw_menu ;;
            3) fail2ban_menu ;;
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
        menu_item "3" "安装 XanMod 内核（BBRv3）"
        menu_item "4" "自动更新与自动重启"
        echo
        menu_item "0" "返回"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) swap_menu ;;
            2) set_timezone ;;
            3) install_xanmod_kernel ;;
            4) configure_auto_updates ;;
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
        menu_item "1" "IP 检测 / 路由追踪 / Debian 重装"
        menu_item "2" "SSH 与安全防护（SSH / UFW / Fail2Ban）"
        menu_item "3" "系统维护（Swap / 时区 / 内核 / 自动更新）"
        menu_item "4" "网络设置（TCP 调优 / IPv6 / MTU）"
        echo
        menu_item "0" "返回主菜单"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1) test_and_reinstall_menu ;;
            2) security_tools_menu ;;
            3) system_tools_menu ;;
            4) network_tools_menu ;;
            0) return ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}
