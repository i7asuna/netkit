#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Variables
########################################

SCRIPT_DIR="/root/xray-manager"

SYSTEM_SCRIPT="${SCRIPT_DIR}/system/01-system.sh"
INSTALL_SCRIPT="${SCRIPT_DIR}/core/02-xray-core.sh"
VLESS_SCRIPT="${SCRIPT_DIR}/core/03-vless.sh"
SS_SCRIPT="${SCRIPT_DIR}/core/04-shadowsocks.sh"

CONFIG_DIR="/usr/local/etc/xray"
CLIENT_DIR="${CONFIG_DIR}/client"
PROTOCOL_DIR="${CONFIG_DIR}/protocols"

CONFIG_FILE="${CONFIG_DIR}/config.json"

XRAY_SERVICE="xray"

########################################
# Colors
########################################

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

########################################
# Common Functions
########################################

pause(){

    echo

    read -rp "Press Enter to continue..."

}

success(){

    echo

    echo -e "${GREEN}$1${RESET}"

}

warning(){

    echo

    echo -e "${YELLOW}$1${RESET}"

}

error(){

    echo

    echo -e "${RED}$1${RESET}"

}

header(){

    clear

    echo "=========================================="

    echo -e "${CYAN}             Xray Manager${RESET}"
    echo "       VLESS • Shadowsocks"

    echo "=========================================="

}


run_script(){
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo "[ERROR] Script not found: $file"
        pause
        return 1
    fi

    bash "$file"
}

########################################
# System Functions
########################################

configure_system(){

    run_script "$SYSTEM_SCRIPT"

}

install_xray(){

    run_script "$INSTALL_SCRIPT"

}

restart_xray(){

    header

    echo "Restarting Xray..."

    echo

    systemctl restart "$XRAY_SERVICE"

    sleep 1

    if systemctl is-active --quiet "$XRAY_SERVICE"; then

        success "Xray restarted successfully."

    else

        error "Xray failed to restart."

    fi

    pause

}

update_xray(){

    header

    warning "Updating Xray..."

    bash <(
        curl -fsSL -L \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh
    ) install

    echo

    if command -v xray >/dev/null 2>&1; then

        xray version | head -n1

    fi

    pause

}

########################################
# Protocol Functions
########################################

configure_vless(){

    run_script "$VLESS_SCRIPT"

}

configure_shadowsocks(){

    run_script "$SS_SCRIPT"

}

########################################
# View Functions
########################################

show_client_links(){

    header

    echo "================== VLESS =================="
    echo

    if [[ -f "${CLIENT_DIR}/vless.txt" ]]; then

        cat "${CLIENT_DIR}/vless.txt"

    else

        warning "Not Configured"

    fi

    echo
    echo "=============== Shadowsocks ==============="
    echo

    if [[ -f "${CLIENT_DIR}/shadowsocks.txt" ]]; then

        cat "${CLIENT_DIR}/shadowsocks.txt"

    else

        warning "Not Configured"

    fi

    pause

}

show_status(){

    header

    STATUS=$(systemctl is-active "$XRAY_SERVICE" 2>/dev/null || echo "unknown")

    if [[ "$STATUS" == "active" ]]; then

        success "Xray Status : Running"

    else

        error "Xray Status : ${STATUS}"

    fi

    echo

    if command -v xray >/dev/null 2>&1; then

        echo "Version"

        xray version | head -n1

    fi

    pause

}

########################################
# Tools Menu
########################################

tools_menu(){

    while true; do

        header

        echo "1. View Config"
        echo "2. View Protocol Config"
        echo
        echo "0. Back"
        echo

        read -rp "Select: " CHOICE

        case "$CHOICE" in

            1)

                header

                if [[ -f "$CONFIG_FILE" ]]; then

                    cat "$CONFIG_FILE"

                else

                    warning "Config not found."

                fi

                pause

                ;;

            2)

                header

                echo "================== VLESS =================="
                echo

                if [[ -f "${PROTOCOL_DIR}/vless.json" ]]; then

                    cat "${PROTOCOL_DIR}/vless.json"

                else

                    warning "Not Configured"

                fi

                echo
                echo "=============== Shadowsocks ==============="
                echo

                if [[ -f "${PROTOCOL_DIR}/shadowsocks.json" ]]; then

                    cat "${PROTOCOL_DIR}/shadowsocks.json"

                else

                    warning "Not Configured"

                fi

                pause

                ;;

            0)

                return

                ;;

            *)

                echo

                echo "Invalid selection."

                pause

                ;;

        esac

    done

}

########################################
# Main Menu
########################################

main_menu(){

    while true; do

        header

        echo "1. Install Xray Core"
        echo "2. Configure VLESS Reality"
        echo "3. Configure Shadowsocks"
        echo
        echo "------------------------------------------"
        echo
        echo "4. Show Client Links"
        echo "5. Show Xray Status"
        echo "6. Restart Xray"
        echo "7. Update Xray Core"
        echo
        echo "------------------------------------------"
        echo
        echo "8. Tools"
        echo "66. System"
        echo
        echo "------------------------------------------"
        echo
        echo "0. Exit"
        echo

        read -rp "Select: " CHOICE

        case "$CHOICE" in
            66)

                configure_system

                ;;

            1)

                install_xray

                ;;

            2)

                configure_vless

                ;;

            3)

                configure_shadowsocks

                ;;

            4)

                show_client_links

                ;;

            5)

                show_status

                ;;

            6)

                restart_xray

                ;;

            7)

                update_xray

                ;;

            8)

                tools_menu

                ;;

            0)

                clear

                exit 0

                ;;

            *)

                error "Invalid selection."

                pause

                ;;

        esac

    done

}

########################################
# Main
########################################

main_menu