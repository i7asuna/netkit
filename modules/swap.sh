#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

SWAPFILE="/swapfile"

install_swap(){
    header "安装虚拟内存"

    if ! require_commands swapon mkswap; then
        pause
        return
    fi
    if ! command -v fallocate >/dev/null 2>&1 && ! command -v dd >/dev/null 2>&1; then
        error "缺少必要命令：fallocate 或 dd。"
        pause
        return
    fi

    if [[ -n "$(swapon --show)" ]]; then
        warning "虚拟内存已存在。"
        pause
        return
    fi

    info "正在创建 1G 虚拟内存..."
    if ! fallocate -l 1G "$SWAPFILE" 2>/dev/null && \
       ! dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024; then
        error "虚拟内存文件创建失败。"
        pause
        return
    fi
    if ! chmod 600 "$SWAPFILE" || ! mkswap "$SWAPFILE" || ! swapon "$SWAPFILE"; then
        error "虚拟内存启用失败。"
        pause
        return
    fi
    grep -q "^${SWAPFILE}" /etc/fstab || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
    success "虚拟内存已创建。"
    pause
}

delete_swap(){
    header "删除虚拟内存"
    warning "正在删除虚拟内存..."

    if ! require_commands swapoff; then
        pause
        return
    fi

    swapoff "$SWAPFILE" 2>/dev/null || true
    if ! sed -i "\#^${SWAPFILE}#d" /etc/fstab || ! rm -f "$SWAPFILE"; then
        error "虚拟内存删除失败。"
        pause
        return
    fi

    success "虚拟内存已删除。"
    pause
}

show_swap_status(){
    header "虚拟内存状态"

    if ! require_commands swapon free; then
        pause
        return
    fi

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
