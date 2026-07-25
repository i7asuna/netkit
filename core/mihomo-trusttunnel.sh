#!/usr/bin/env bash
# Mihomo TrustTunnel 入站配置脚本

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONFIG="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/trusttunnel.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/trusttunnel.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
CERT_FILE="${MIHOMO_DIR}/certs/fullchain.pem"
KEY_FILE="${MIHOMO_DIR}/certs/private.key"
DOMAIN_FILE="${MIHOMO_DIR}/certs/domain"
MIN_MIHOMO_VERSION="1.19.25"

PORT=""
USERNAME=""
PASSWORD=""
DOMAIN=""
SERVER_IP=""
TRANSPORT_TEXT=""
CONGESTION_CONTROLLER=""
BBR_PROFILE=""
REUSE_MODE="pool"
MAX_CONNECTIONS="8"
MIN_STREAMS="5"
MAX_STREAMS=""

NEW_HAS_TCP=false
NEW_HAS_UDP=false
OLD_HAS_TCP=false
OLD_HAS_UDP=false
OLD_PORT=""
PROTOCOL_BACKUP=""
CONFIG_BACKUP=""
CLIENT_BACKUP=""
UFW_TCP_ADDED=0
UFW_UDP_ADDED=0

trap 'rc=$?; echo; error "TrustTunnel 配置失败：第 ${LINENO} 行（退出码：${rc}）"; exit "${rc}"' ERR

check_root(){
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

install_dependencies(){
    local missing=()
    local package

    for package in curl openssl coreutils iproute2; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing+=("${package}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        info "正在安装 Mihomo TrustTunnel 环境依赖..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
    fi
}

check_mihomo(){
    local installed_version

    if ! command -v mihomo >/dev/null 2>&1; then
        error "未检测到 Mihomo，请先安装 Mihomo 内核。"
        exit 1
    fi
    if [[ ! -x "${BUILD_CONFIG_SCRIPT}" ]]; then
        error "未找到配置构建脚本：${BUILD_CONFIG_SCRIPT}"
        exit 1
    fi

    installed_version=$(
        mihomo -v 2>/dev/null |
        grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
        head -n1 |
        sed 's/^v//' ||
        true
    )
    if [[ -z "${installed_version}" ]] ||
       ! dpkg --compare-versions "${installed_version}" ge "${MIN_MIHOMO_VERSION}"; then
        error "TrustTunnel 当前选项需要 Mihomo v${MIN_MIHOMO_VERSION} 或更高版本。"
        error "当前版本：${installed_version:-未知}，请先更新 Mihomo。"
        exit 1
    fi
}

check_certificate(){
    local cert_public_key key_public_key

    info "检查 TrustTunnel TLS 证书..."
    if [[ ! -r "${CERT_FILE}" || ! -r "${KEY_FILE}" || ! -r "${DOMAIN_FILE}" ]]; then
        error "未找到可用的 TLS 证书。"
        echo "请先在 Mihomo 菜单中运行“TLS 证书申请与管理”。"
        exit 1
    fi

    DOMAIN="$(tr -d '\r\n' < "${DOMAIN_FILE}")"
    [[ -n "${DOMAIN}" ]] || { error "证书域名记录为空：${DOMAIN_FILE}"; exit 1; }
    openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1 ||
        { error "证书文件无效：${CERT_FILE}"; exit 1; }
    openssl pkey -in "${KEY_FILE}" -noout >/dev/null 2>&1 ||
        { error "私钥文件无效：${KEY_FILE}"; exit 1; }
    openssl x509 -in "${CERT_FILE}" -noout -checkend 0 >/dev/null 2>&1 ||
        { error "TLS 证书已经过期，请先续期。"; exit 1; }
    openssl x509 -in "${CERT_FILE}" -noout -checkhost "${DOMAIN}" >/dev/null 2>&1 ||
        { error "TLS 证书不包含域名：${DOMAIN}"; exit 1; }

    cert_public_key="$(openssl x509 -in "${CERT_FILE}" -pubkey -noout |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"
    key_public_key="$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"
    if [[ -z "${cert_public_key}" || "${cert_public_key}" != "${key_public_key}" ]]; then
        error "TLS 证书与私钥不匹配。"
        exit 1
    fi
    success "TLS 证书有效：${DOMAIN}"
}

get_server_ip(){
    SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    fi
    [[ -n "${SERVER_IP}" ]] || SERVER_IP="未知"
}

show_dns_warning(){
    local resolved_ip

    resolved_ip="$(getent ahosts "${DOMAIN}" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ -z "${resolved_ip}" ]]; then
        warning "域名 ${DOMAIN} 当前未解析；客户端连接前请设置正确的 A 或 AAAA 记录。"
    else
        info "域名当前解析到：${resolved_ip}"
    fi
}

read_old_config(){
    [[ -f "${PROTOCOL_CONFIG}" ]] || return 0

    OLD_PORT="$(yaml_number_field "${PROTOCOL_CONFIG}" "port" || true)"
    grep -Eq '^[[:space:]]*network:.*"tcp"' "${PROTOCOL_CONFIG}" && OLD_HAS_TCP=true
    grep -Eq '^[[:space:]]*network:.*"udp"' "${PROTOCOL_CONFIG}" && OLD_HAS_UDP=true
    if ! ${OLD_HAS_TCP} && ! ${OLD_HAS_UDP}; then
        OLD_HAS_TCP=true
    fi
    return 0
}

prompt_transport(){
    local choice

    echo
    menu_item "1" "H2（外层 TCP，兼容性好）"
    menu_item "2" "H3（外层 QUIC/UDP，网络需支持 UDP）"
    menu_item "3" "H2 + H3（同端口同时开放，生成两个客户端节点）"
    echo
    menu_item "0" "取消"
    echo
    read -r -p "$(prompt_text "请选择 TrustTunnel 传输模式 [3]: ")" choice
    choice="${choice:-3}"

    case "${choice}" in
        1)
            NEW_HAS_TCP=true
            TRANSPORT_TEXT="H2"
            ;;
        2)
            NEW_HAS_UDP=true
            TRANSPORT_TEXT="H3"
            ;;
        3)
            NEW_HAS_TCP=true
            NEW_HAS_UDP=true
            TRANSPORT_TEXT="H2 + H3"
            ;;
        0)
            cancel_input "${choice}"
            exit "${INPUT_CANCEL_STATUS}"
            ;;
        *)
            error "无效选择。"
            exit 1
            ;;
    esac
    info "H2/H3 分别生成独立节点，客户端 ALPN 由 Mihomo 自动匹配。"
}

tcp_port_in_use(){
    local port="$1"
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
}

udp_port_in_use(){
    local port="$1"
    ss -lunH 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
}

prompt_port(){
    local input candidate

    while true; do
        read -r -p "$(prompt_text "监听端口（默认 443，输入 0 取消）: ")" input
        input="${input:-443}"
        if [[ "${input}" == "0" ]]; then
            cancel_input "${input}"
            exit "${INPUT_CANCEL_STATUS}"
        fi
        if ! valid_port "${input}"; then
            warning "端口必须是 1-65535 的整数。"
            continue
        fi
        candidate=$((10#${input}))

        if ${NEW_HAS_TCP} && tcp_port_in_use "${candidate}"; then
            if [[ "${candidate}" != "${OLD_PORT}" ]] || ! ${OLD_HAS_TCP}; then
                warning "TCP 端口 ${candidate} 已被占用。"
                continue
            fi
        fi
        if ${NEW_HAS_UDP} && udp_port_in_use "${candidate}"; then
            if [[ "${candidate}" != "${OLD_PORT}" ]] || ! ${OLD_HAS_UDP}; then
                warning "UDP 端口 ${candidate} 已被占用。"
                continue
            fi
        fi

        PORT="${candidate}"
        return 0
    done
}

prompt_quic_options(){
    local choice profile_choice

    ${NEW_HAS_UDP} || return 0

    echo
    menu_item "1" "BBR（推荐，适合多数公网线路）"
    menu_item "2" "CUBIC（传统稳健）"
    menu_item "3" "New Reno（更保守）"
    echo
    menu_item "0" "取消"
    echo
    read -r -p "$(prompt_text "请选择 QUIC 拥塞控制 [1]: ")" choice
    choice="${choice:-1}"
    case "${choice}" in
        1) CONGESTION_CONTROLLER="bbr" ;;
        2) CONGESTION_CONTROLLER="cubic" ;;
        3) CONGESTION_CONTROLLER="new_reno" ;;
        0)
            cancel_input "${choice}"
            exit "${INPUT_CANCEL_STATUS}"
            ;;
        *)
            error "无效选择。"
            exit 1
            ;;
    esac

    [[ "${CONGESTION_CONTROLLER}" == "bbr" ]] || return 0
    echo
    menu_item "1" "standard（推荐，均衡）"
    menu_item "2" "conservative（保守）"
    menu_item "3" "aggressive（积极）"
    echo
    menu_item "0" "取消"
    echo
    read -r -p "$(prompt_text "请选择 BBR Profile [1]: ")" profile_choice
    profile_choice="${profile_choice:-1}"
    case "${profile_choice}" in
        1) BBR_PROFILE="standard" ;;
        2) BBR_PROFILE="conservative" ;;
        3) BBR_PROFILE="aggressive" ;;
        0)
            cancel_input "${profile_choice}"
            exit "${INPUT_CANCEL_STATUS}"
            ;;
        *)
            error "无效选择。"
            exit 1
            ;;
    esac
}

prompt_positive_integer(){
    local message="$1"
    local default_value="$2"
    local max_value="$3"
    local input

    while true; do
        read -r -p "$(prompt_text "${message} [${default_value}]: ")" input
        input="${input:-${default_value}}"
        if [[ "${input}" == "0" ]]; then
            cancel_input "${input}" >&2
            return "${INPUT_CANCEL_STATUS}"
        fi
        if [[ "${input}" =~ ^[0-9]+$ ]] &&
           (( 10#${input} >= 1 && 10#${input} <= max_value )); then
            printf '%s' "$((10#${input}))"
            return 0
        fi
        warning "请输入 1-${max_value} 的整数。" >&2
    done
}

prompt_reuse_options(){
    local choice status

    echo
    menu_item "1" "默认连接池（最多 8 条连接，每条至少 5 个流）"
    menu_item "2" "自定义连接池（max-connections + min-streams）"
    menu_item "3" "按流数新建连接（仅 max-streams）"
    echo
    menu_item "0" "取消"
    echo
    read -r -p "$(prompt_text "请选择客户端连接复用方式 [1]: ")" choice
    choice="${choice:-1}"

    case "${choice}" in
        1)
            REUSE_MODE="pool"
            MAX_CONNECTIONS="8"
            MIN_STREAMS="5"
            MAX_STREAMS=""
            ;;
        2)
            REUSE_MODE="pool"
            MAX_CONNECTIONS="$(prompt_positive_integer "最大连接数" "8" "64")" || {
                status=$?
                exit "${status}"
            }
            MIN_STREAMS="$(prompt_positive_integer "每条连接达到多少个流后新建连接" "5" "1024")" || {
                status=$?
                exit "${status}"
            }
            MAX_STREAMS=""
            ;;
        3)
            REUSE_MODE="streams"
            MAX_STREAMS="$(prompt_positive_integer "每条连接的最大流数" "16" "4096")" || {
                status=$?
                exit "${status}"
            }
            MAX_CONNECTIONS=""
            MIN_STREAMS=""
            ;;
        0)
            cancel_input "${choice}"
            exit "${INPUT_CANCEL_STATUS}"
            ;;
        *)
            error "无效选择。"
            exit 1
            ;;
    esac
}

generate_credentials(){
    USERNAME="netkit-$(openssl rand -hex 6)"
    PASSWORD="$(openssl rand -hex 24)"
    if [[ -z "${USERNAME}" || -z "${PASSWORD}" ]]; then
        error "TrustTunnel 用户凭据生成失败。"
        exit 1
    fi
}

backup_configs(){
    if [[ -f "${PROTOCOL_CONFIG}" ]]; then
        PROTOCOL_BACKUP="$(mktemp /tmp/netkit-trusttunnel.XXXXXX.yaml)"
        cp -a "${PROTOCOL_CONFIG}" "${PROTOCOL_BACKUP}"
    fi
    if [[ -f "${MIHOMO_CONFIG}" ]]; then
        CONFIG_BACKUP="$(mktemp /tmp/netkit-mihomo-config.XXXXXX.yaml)"
        cp -a "${MIHOMO_CONFIG}" "${CONFIG_BACKUP}"
    fi
    if [[ -f "${CLIENT_FILE}" ]]; then
        CLIENT_BACKUP="$(mktemp /tmp/netkit-trusttunnel-client.XXXXXX.txt)"
        cp -a "${CLIENT_FILE}" "${CLIENT_BACKUP}"
    fi
}

restore_file(){
    local backup="$1"
    local target="$2"

    if [[ -n "${backup}" && -f "${backup}" ]]; then
        cp -a "${backup}" "${target}"
    else
        rm -f "${target}"
    fi
}

rollback(){
    warning "正在回滚 TrustTunnel 配置..."
    restore_file "${PROTOCOL_BACKUP}" "${PROTOCOL_CONFIG}"
    restore_file "${CONFIG_BACKUP}" "${MIHOMO_CONFIG}"
    restore_file "${CLIENT_BACKUP}" "${CLIENT_FILE}"
    (( UFW_TCP_ADDED == 0 )) || remove_ufw_port_rule "${PORT}" tcp
    (( UFW_UDP_ADDED == 0 )) || remove_ufw_port_rule "${PORT}" udp
    systemctl restart mihomo >/dev/null 2>&1 || true
}

network_yaml(){
    if ${NEW_HAS_TCP} && ${NEW_HAS_UDP}; then
        printf '["tcp", "udp"]'
    elif ${NEW_HAS_TCP}; then
        printf '["tcp"]'
    else
        printf '["udp"]'
    fi
}

write_protocol_config(){
    local yaml_username yaml_password yaml_cert yaml_key

    yaml_username="$(yaml_quote "${USERNAME}")"
    yaml_password="$(yaml_quote "${PASSWORD}")"
    yaml_cert="$(yaml_quote "${CERT_FILE}")"
    yaml_key="$(yaml_quote "${KEY_FILE}")"

    umask 077
    mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"
    {
        echo "  - name: trusttunnel-in"
        echo "    type: trusttunnel"
        echo "    port: ${PORT}"
        echo "    listen: 0.0.0.0"
        echo "    users:"
        echo "      - username: ${yaml_username}"
        echo "        password: ${yaml_password}"
        echo "    certificate: ${yaml_cert}"
        echo "    private-key: ${yaml_key}"
        echo "    network: $(network_yaml)"
        if ${NEW_HAS_UDP}; then
            echo "    congestion-controller: ${CONGESTION_CONTROLLER}"
            if [[ "${CONGESTION_CONTROLLER}" == "bbr" ]]; then
                echo "    bbr-profile: ${BBR_PROFILE}"
            fi
        fi
    } > "${PROTOCOL_CONFIG}"
    chmod 600 "${PROTOCOL_CONFIG}"
}

write_reuse_yaml(){
    if [[ "${REUSE_MODE}" == "pool" ]]; then
        echo "  max-connections: ${MAX_CONNECTIONS}"
        echo "  min-streams: ${MIN_STREAMS}"
    else
        echo "  max-streams: ${MAX_STREAMS}"
    fi
}

write_client_proxy(){
    local mode="$1"
    local yaml_domain yaml_username yaml_password

    yaml_domain="$(yaml_quote "${DOMAIN}")"
    yaml_username="$(yaml_quote "${USERNAME}")"
    yaml_password="$(yaml_quote "${PASSWORD}")"

    echo "- name: Mihomo TrustTunnel ${mode}"
    echo "  type: trusttunnel"
    echo "  server: ${yaml_domain}"
    echo "  port: ${PORT}"
    echo "  username: ${yaml_username}"
    echo "  password: ${yaml_password}"
    echo "  health-check: true"
    echo "  udp: true"
    echo "  sni: ${yaml_domain}"
    echo "  skip-cert-verify: false"
    if [[ "${mode}" == "H2" ]]; then
        echo "  quic: false"
        echo "  client-fingerprint: chrome"
    else
        echo "  quic: true"
        echo "  congestion-controller: ${CONGESTION_CONTROLLER}"
        if [[ "${CONGESTION_CONTROLLER}" == "bbr" ]]; then
            echo "  bbr-profile: ${BBR_PROFILE}"
        fi
    fi
    write_reuse_yaml
}

write_client_info(){
    umask 077
    {
        echo "Mihomo / Clash:"
        if ${NEW_HAS_TCP}; then
            write_client_proxy "H2"
        fi
        if ${NEW_HAS_UDP}; then
            write_client_proxy "H3"
        fi
    } > "${CLIENT_FILE}"
    chmod 600 "${CLIENT_FILE}"
}

add_firewall_rules(){
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0

    if ${NEW_HAS_TCP} &&
       ! ufw status 2>/dev/null | grep -Eq "^${PORT}/tcp[[:space:]]"; then
        info "放行 TrustTunnel TCP ${PORT}..."
        if ! ufw allow "${PORT}/tcp" comment "Mihomo TrustTunnel H2" >/dev/null; then
            return 1
        fi
        UFW_TCP_ADDED=1
    fi
    if ${NEW_HAS_UDP} &&
       ! ufw status 2>/dev/null | grep -Eq "^${PORT}/udp[[:space:]]"; then
        info "放行 TrustTunnel UDP ${PORT}..."
        if ! ufw allow "${PORT}/udp" comment "Mihomo TrustTunnel H3" >/dev/null; then
            return 1
        fi
        UFW_UDP_ADDED=1
    fi
}

apply_config(){
    info "构建并验证 Mihomo 配置..."
    if ! "${BUILD_CONFIG_SCRIPT}"; then
        rollback
        error "Mihomo 配置验证失败，已恢复原配置。"
        exit 1
    fi
    if ! add_firewall_rules; then
        rollback
        error "TrustTunnel 防火墙规则添加失败，已恢复原配置。"
        exit 1
    fi
    if ! systemctl restart mihomo || ! systemctl is-active --quiet mihomo; then
        rollback
        error "Mihomo 启动失败，已恢复原配置。"
        journalctl -u mihomo -n 20 --no-pager 2>/dev/null || true
        exit 1
    fi
}

remove_old_firewall_rules(){
    [[ -n "${OLD_PORT}" ]] || return 0

    if ${OLD_HAS_TCP}; then
        if [[ "${OLD_PORT}" != "${PORT}" ]] || ! ${NEW_HAS_TCP}; then
            remove_ufw_port_rule "${OLD_PORT}" tcp
        fi
    fi
    if ${OLD_HAS_UDP}; then
        if [[ "${OLD_PORT}" != "${PORT}" ]] || ! ${NEW_HAS_UDP}; then
            remove_ufw_port_rule "${OLD_PORT}" udp
        fi
    fi
}

cleanup_backups(){
    [[ -z "${PROTOCOL_BACKUP}" ]] || rm -f "${PROTOCOL_BACKUP}"
    [[ -z "${CONFIG_BACKUP}" ]] || rm -f "${CONFIG_BACKUP}"
    [[ -z "${CLIENT_BACKUP}" ]] || rm -f "${CLIENT_BACKUP}"
}

show_result(){
    local reuse_text

    if [[ "${REUSE_MODE}" == "pool" ]]; then
        reuse_text="${MAX_CONNECTIONS} connections / ${MIN_STREAMS} streams"
    else
        reuse_text="max-streams ${MAX_STREAMS}"
    fi

    banner "Mihomo TrustTunnel 安装成功" "$GREEN"
    kv "Server IP :" "${SERVER_IP}"
    kv "Domain    :" "${DOMAIN}"
    kv "Port      :" "${PORT}"
    kv "Transport :" "${TRANSPORT_TEXT}"
    if ${NEW_HAS_UDP}; then
        kv "QUIC CC   :" "${CONGESTION_CONTROLLER}"
        [[ -z "${BBR_PROFILE}" ]] || kv "BBR Profile:" "${BBR_PROFILE}"
    fi
    kv "Reuse     :" "${reuse_text}"
    kv "Username  :" "${USERNAME}"
    kv "Password  :" "${PASSWORD}"
    kv "Routing   :" "全局 DIRECT"
    echo
    path_kv "主配置文件      :" "${MIHOMO_CONFIG}"
    path_kv "协议配置文件    :" "${PROTOCOL_CONFIG}"
    path_kv "连接信息文件    :" "${CLIENT_FILE}"
    path_kv "TLS 证书        :" "${CERT_FILE}"
    echo
    label " Mihomo / Clash YAML"
    echo
    sed -n '/^Mihomo \/ Clash:/,$p' "${CLIENT_FILE}" |
        tail -n +2 |
        while IFS= read -r line; do value "${line}"; done
    echo
    divider "$GREEN"
}

main(){
    check_root
    banner "安装 Mihomo TrustTunnel"
    install_dependencies
    check_mihomo
    check_certificate
    get_server_ip
    show_dns_warning
    read_old_config
    prompt_transport
    prompt_port
    prompt_quic_options
    prompt_reuse_options
    generate_credentials
    backup_configs
    write_protocol_config
    write_client_info
    apply_config
    remove_old_firewall_rules
    cleanup_backups
    show_result
}

main "$@"
