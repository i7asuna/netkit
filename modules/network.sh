#!/usr/bin/env bash
# Sourced by netkit.sh; do not execute directly.

IPV6_SYSCTL_CONFIG="/etc/sysctl.d/99-netkit-ipv6.conf"
SYSCTL_CONFIG="/etc/sysctl.d/99-z-bbr.conf"
NETWORK_INTERFACES_CONFIG="/etc/network/interfaces"
MTU_VALUE=1500

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

    if ! require_commands sysctl; then
        pause
        return
    fi

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

net.core.netdev_max_backlog = 2048
net.core.somaxconn = 1024

net.core.rmem_max = 4194304
net.core.wmem_max = 4194304

net.ipv4.tcp_rmem = 4096 131072 4194304
net.ipv4.tcp_wmem = 4096 131072 4194304

net.ipv4.tcp_moderate_rcvbuf = 1

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

net.ipv4.tcp_max_syn_backlog = 2048

net.netfilter.nf_conntrack_max = 32768
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

vm.swappiness = 10
EOF

    if ! sysctl --system >/dev/null; then
        error "系统调优参数应用失败。"
        pause
        return
    fi

    success "系统调优已完成。"

    echo
    section "调优后参数" "$YELLOW"
    echo "BBR:   $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "Qdisc: $(sysctl -n net.core.default_qdisc)"
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
    if ! require_commands ip awk dpkg mktemp; then
        pause
        return
    fi

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

    if ! require_commands sysctl; then
        pause
        return
    fi

    if ! sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null || \
       ! sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null; then
        error "IPv6 开启失败。"
        pause
        return
    fi

    rm -f "$IPV6_SYSCTL_CONFIG"
    success "IPv6 已开启。"
    pause
}

disable_ipv6(){
    header "关闭 IPv6"
    warning "正在关闭 IPv6..."

    if ! require_commands sysctl; then
        pause
        return
    fi

    if ! sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null || \
       ! sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null; then
        error "IPv6 关闭失败。"
        pause
        return
    fi

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
