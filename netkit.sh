#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="${NETKIT_ROOT:-/root/netkit}"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=/root/netkit/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/root/netkit/modules/mihomo.sh
source "${SCRIPT_DIR}/modules/mihomo.sh"
# shellcheck source=/root/netkit/modules/ssh.sh
source "${SCRIPT_DIR}/modules/ssh.sh"
# shellcheck source=/root/netkit/modules/ufw.sh
source "${SCRIPT_DIR}/modules/ufw.sh"
# shellcheck source=/root/netkit/modules/fail2ban.sh
source "${SCRIPT_DIR}/modules/fail2ban.sh"
# shellcheck source=/root/netkit/modules/swap.sh
source "${SCRIPT_DIR}/modules/swap.sh"
# shellcheck source=/root/netkit/modules/system.sh
source "${SCRIPT_DIR}/modules/system.sh"
# shellcheck source=/root/netkit/modules/network.sh
source "${SCRIPT_DIR}/modules/network.sh"
# shellcheck source=/root/netkit/modules/external-tools.sh
source "${SCRIPT_DIR}/modules/external-tools.sh"
# shellcheck source=/root/netkit/modules/tools-menu.sh
source "${SCRIPT_DIR}/modules/tools-menu.sh"

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_menu
fi
