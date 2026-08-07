#!/usr/bin/env bash
# Mihomo Hysteria2 入站配置脚本
# 说明：按照 Mihomo 官方 Hysteria2 listener 格式生成配置。

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONFIG="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/hysteria2.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/hysteria2.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
HOP_HELPER="${SCRIPT_DIR}/core/mihomo-hysteria2-port-hopping.sh"
HOP_SERVICE="mihomo-hysteria2-port-hopping.service"
HOP_SERVICE_FILE="/etc/systemd/system/${HOP_SERVICE}"
HOP_DROPIN_DIR="/etc/systemd/system/mihomo.service.d"
HOP_DROPIN_FILE="${HOP_DROPIN_DIR}/hysteria2-port-hopping.conf"
HOP_STATE_FILE="${MIHOMO_DIR}/hysteria2-port-hopping.range"
CERT_DIR="${MIHOMO_DIR}/certs"
SELF_SIGNED_DIR="${CERT_DIR}/hysteria2-selfsigned"
SELF_SIGNED_CERT_FILE="${SELF_SIGNED_DIR}/server.crt"
SELF_SIGNED_KEY_FILE="${SELF_SIGNED_DIR}/private.key"
SELF_SIGNED_DOMAIN_FILE="${SELF_SIGNED_DIR}/domain"
SELF_SIGNED_DAYS="3650"
CERT_FILE="${SELF_SIGNED_CERT_FILE}"
KEY_FILE="${SELF_SIGNED_KEY_FILE}"
DOMAIN_FILE="${SELF_SIGNED_DOMAIN_FILE}"
USERNAME="netkit"
MASQUERADE_DIR="${MIHOMO_DIR}/masquerade"
MASQUERADE_INDEX="${MASQUERADE_DIR}/index.html"
MASQUERADE_URI="file://${MASQUERADE_DIR}"
HOP_MIN="20000"
HOP_MAX="50000"
HOP_START="${HOP_MIN}"
HOP_END="${HOP_MAX}"
HOP_INTERVAL="30"

PORT=""
PASSWORD=""
HY2_MODE="standard"
MASQUERADE_URL=""
OBFS_PASSWORD=""
DOMAIN=""
SERVER_IP=""
CERT_FINGERPRINT=""
OLD_PORT=""
OLD_HOP_START=""
OLD_HOP_END=""
PROTOCOL_BACKUP=""
CONFIG_BACKUP=""
SERVICE_BACKUP=""
UFW_RULE_ADDED=0
HAD_OLD_CONFIG=0

trap 'rc=$?; echo; err "Hysteria2 配置失败：第 ${LINENO} 行，命令：${BASH_COMMAND}（退出码：${rc}）"; exit "${rc}"' ERR

err() { error "$@"; }
warn() { warning "$@"; }
ok() { success "$@"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 用户运行此脚本"
        exit 1
    fi
}

install_dependencies() {
    local missing=()
    local package

    for package in curl openssl coreutils iproute2 nftables; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing+=("${package}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        info "正在安装 Mihomo Hysteria2 环境依赖..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
    fi
}

check_mihomo() {
    if ! command -v mihomo >/dev/null 2>&1; then
        err "未检测到 Mihomo，请先安装 Mihomo 内核"
        exit 1
    fi

    if [[ ! -x "${BUILD_CONFIG_SCRIPT}" ]]; then
        err "未找到配置构建脚本：${BUILD_CONFIG_SCRIPT}"
        exit 1
    fi

    if [[ ! -r "${HOP_HELPER}" ]]; then
        err "未找到 Hysteria2 端口跳跃规则脚本：${HOP_HELPER}"
        exit 1
    fi
}

certificate_material_valid() {
    local cert_file="$1"
    local key_file="$2"
    local domain="$3"
    local cert_public_key=""
    local key_public_key=""

    [[ -r "${cert_file}" && -r "${key_file}" && -n "${domain}" ]] || return 1
    openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "${key_file}" -noout >/dev/null 2>&1 || return 1
    openssl x509 -in "${cert_file}" -noout -checkend 0 >/dev/null 2>&1 || return 1
    openssl x509 -in "${cert_file}" -noout -checkhost "${domain}" >/dev/null 2>&1 || return 1

    cert_public_key="$(openssl x509 -in "${cert_file}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_public_key="$(openssl pkey -in "${key_file}" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "${cert_public_key}" && "${cert_public_key}" == "${key_public_key}" ]]
}

check_certificate() {
    info "检查 Hysteria2 TLS 证书..."

    if [[ ! -r "${CERT_FILE}" || ! -r "${KEY_FILE}" || ! -r "${DOMAIN_FILE}" ]]; then
        err "未找到可用的 TLS 证书"

        echo "证书路径：${CERT_FILE}"
        echo "私钥路径：${KEY_FILE}"
        exit 1
    fi

    DOMAIN="$(tr -d '\r\n' < "${DOMAIN_FILE}")"
    if [[ -z "${DOMAIN}" ]]; then
        err "证书域名记录为空：${DOMAIN_FILE}"
        exit 1
    fi

    if ! openssl x509 -in "${CERT_FILE}" -noout >/dev/null 2>&1; then
        err "证书文件无效：${CERT_FILE}"
        exit 1
    fi

    if ! openssl pkey -in "${KEY_FILE}" -noout >/dev/null 2>&1; then
        err "私钥文件无效：${KEY_FILE}"
        exit 1
    fi

    if ! openssl x509 -in "${CERT_FILE}" -noout -checkend 0 >/dev/null 2>&1; then
        err "TLS 证书已经过期，请先续期或重新生成证书"
        exit 1
    fi

    if ! openssl x509 -in "${CERT_FILE}" -noout -checkhost "${DOMAIN}" >/dev/null 2>&1; then
        err "TLS 证书不包含域名：${DOMAIN}"
        exit 1
    fi

    local cert_public_key key_public_key
    cert_public_key="$(openssl x509 -in "${CERT_FILE}" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_public_key="$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    if [[ -z "${cert_public_key}" || "${cert_public_key}" != "${key_public_key}" ]]; then
        err "TLS 证书与私钥不匹配"
        exit 1
    fi

    ok "TLS 证书有效：${DOMAIN}"
}

normalize_hy2_domain() {
    local host="$1"

    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    host="${host%.}"

    if [[ -z "${host}" || "${host}" == *:* ]]; then
        return 1
    fi
    if [[ ! "${host}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])$ ]]; then
        return 1
    fi

    printf '%s' "${host,,}"
}

load_certificate_fingerprint() {
    CERT_FINGERPRINT="$(openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//')"
    if [[ ! "${CERT_FINGERPRINT}" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]]; then
        err "无法计算自签证书 SHA-256 指纹"
        exit 1
    fi
}

generate_self_signed_certificate() {
    local temp_dir=""
    local temp_cert=""
    local temp_key=""
    local temp_domain=""

    install -d -m 700 "${SELF_SIGNED_DIR}"
    temp_dir="$(mktemp -d "${SELF_SIGNED_DIR}/.generate.XXXXXX")"
    temp_cert="${temp_dir}/server.crt"
    temp_key="${temp_dir}/private.key"
    temp_domain="${temp_dir}/domain"

    info "正在生成 EC P-256 自签证书（有效期 ${SELF_SIGNED_DAYS} 天）..."
    if ! openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -sha256 -days "${SELF_SIGNED_DAYS}" \
        -keyout "${temp_key}" \
        -out "${temp_cert}" \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1; then
        rm -f "${temp_cert}" "${temp_key}" "${temp_domain}"
        rmdir "${temp_dir}" >/dev/null 2>&1 || true
        err "自签证书生成失败"
        exit 1
    fi
    printf '%s\n' "${DOMAIN}" > "${temp_domain}"

    if ! certificate_material_valid "${temp_cert}" "${temp_key}" "${DOMAIN}"; then
        rm -f "${temp_cert}" "${temp_key}" "${temp_domain}"
        rmdir "${temp_dir}" >/dev/null 2>&1 || true
        err "生成的自签证书验证失败"
        exit 1
    fi

    install -m 644 "${temp_cert}" "${SELF_SIGNED_CERT_FILE}.new"
    install -m 600 "${temp_key}" "${SELF_SIGNED_KEY_FILE}.new"
    install -m 600 "${temp_domain}" "${SELF_SIGNED_DOMAIN_FILE}.new"
    mv -f "${SELF_SIGNED_CERT_FILE}.new" "${SELF_SIGNED_CERT_FILE}"
    mv -f "${SELF_SIGNED_KEY_FILE}.new" "${SELF_SIGNED_KEY_FILE}"
    mv -f "${SELF_SIGNED_DOMAIN_FILE}.new" "${SELF_SIGNED_DOMAIN_FILE}"
    rm -f "${temp_cert}" "${temp_key}" "${temp_domain}"
    rmdir "${temp_dir}" >/dev/null 2>&1 || true
}

prepare_self_signed_certificate() {
    local input=""
    local normalized=""
    local saved_domain=""
    local has_existing=0

    while true; do
        read -r -p "请输入自签证书域名 / SNI（无需 DNS 解析，输入 0 取消）：" input
        if [[ "${input}" == "0" ]]; then
            err "操作已取消"
            exit 1
        fi
        if normalized="$(normalize_hy2_domain "${input}")"; then
            DOMAIN="${normalized}"
            break
        fi
        warn "域名格式无效，请只填写域名，不要填写端口或路径"
    done


    if [[ -e "${CERT_FILE}" || -e "${KEY_FILE}" || -e "${DOMAIN_FILE}" ]]; then
        has_existing=1
    fi
    if [[ -r "${DOMAIN_FILE}" ]]; then
        saved_domain="$(tr -d '\r\n' < "${DOMAIN_FILE}")"
    fi

    if [[ "${saved_domain}" == "${DOMAIN}" ]] && certificate_material_valid "${CERT_FILE}" "${KEY_FILE}" "${DOMAIN}"; then
        ok "复用现有自签证书：${DOMAIN}"
    else
        if (( has_existing == 1 )); then
            warn "现有自签证书不可复用；重新生成后 SHA-256 指纹会变化，客户端必须同步更新"
            if ! prompt_yes_no "是否重新生成自签证书？"; then
                err "操作已取消"
                exit 1
            fi
        fi
        generate_self_signed_certificate
        ok "自签证书生成成功：${DOMAIN}"
    fi

    check_certificate
    load_certificate_fingerprint
}

get_server_ip() {
    SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    fi
    [[ -n "${SERVER_IP}" ]] || SERVER_IP="未知"
}

prompt_hop_range() {
    local input=""
    local default_range="${HOP_MIN}-${HOP_MAX}"
    local candidate_start candidate_end

    if [[ -n "${OLD_HOP_START}" && -n "${OLD_HOP_END}" ]] &&
       (( OLD_HOP_START >= HOP_MIN && OLD_HOP_END <= HOP_MAX )); then
        default_range="${OLD_HOP_START}-${OLD_HOP_END}"
    fi

    while true; do
        read -r -p "请输入 HY2 跳跃端口范围（${HOP_MIN}-${HOP_MAX} 内，默认 ${default_range}，输入 0 取消）: " input
        input="${input:-${default_range}}"
        if [[ "${input}" == "0" ]]; then
            err "操作已取消"
            exit 1
        fi

        if [[ ! "${input}" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
            warn "格式无效，请使用“起始端口-结束端口”，例如 22000-32000"
            continue
        fi

        candidate_start=$((10#${BASH_REMATCH[1]}))
        candidate_end=$((10#${BASH_REMATCH[2]}))
        if (( candidate_start < HOP_MIN || candidate_end > HOP_MAX || candidate_start >= candidate_end )); then
            warn "跳跃范围必须位于 ${HOP_MIN}-${HOP_MAX} 内，并且起始端口小于结束端口"
            continue
        fi

        if [[ "${candidate_start}" != "${OLD_PORT}" ]] && port_in_use "${candidate_start}"; then
            warn "实际监听端口 ${candidate_start} 已被占用，请更换跳跃范围"
            continue
        fi

        HOP_START="${candidate_start}"
        HOP_END="${candidate_end}"
        PORT="${HOP_START}"
        return 0
    done
}

prompt_yes_no() {
    local message="$1"
    local answer=""

    while true; do
        read -r -p "${message} [y/N]: " answer
        case "${answer}" in
            ""|[Nn]) return 1 ;;
            [Yy]) return 0 ;;
            *) warn "请输入 y 或 n，直接回车默认为 n" ;;
        esac
    done
}

prompt_hy2_mode() {
    echo
    echo "Hysteria2 流量模式："
    echo

    if prompt_yes_no "是否启用 HTTP/3 本地静态网页伪装？"; then
        HY2_MODE="masquerade"
        MASQUERADE_URL="${MASQUERADE_URI}"
        info "已选择本地静态网页伪装：${MASQUERADE_URL}"
        return 0
    fi

    if prompt_yes_no "是否启用 Salamander 混淆？"; then
        HY2_MODE="salamander"
        OBFS_PASSWORD="$(openssl rand -hex 32)"
        if [[ -z "${OBFS_PASSWORD}" ]]; then
            err "Salamander 混淆密码生成失败"
            exit 1
        fi
        info "已选择 Salamander 混淆"
    else
        HY2_MODE="standard"
        info "已选择标准 HTTP/3 模式（探测返回 404）"
    fi
}

write_masquerade_site() {
    local temp_file="${MASQUERADE_INDEX}.tmp.$$"

    [[ "${HY2_MODE}" == "masquerade" ]] || return 0
    install -d -m 755 "${MASQUERADE_DIR}"
    if [[ -s "${MASQUERADE_INDEX}" ]]; then
        chmod 644 "${MASQUERADE_INDEX}"
        info "复用现有本地静态网页：${MASQUERADE_INDEX}"
        return 0
    fi

    cat > "${temp_file}" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>404 Not Found</title>
  <style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f5f5f5;color:#222;font:16px/1.5 system-ui,sans-serif}main{text-align:center}h1{margin:0;font-size:72px;font-weight:600}p{margin:8px 0 0;color:#666}</style>
</head>
<body><main><h1>404</h1><p>Page not found.</p></main></body>
</html>
EOF
    chmod 644 "${temp_file}"
    mv -f "${temp_file}" "${MASQUERADE_INDEX}"
    info "本地静态网页已创建：${MASQUERADE_INDEX}"
}

cleanup_unused_masquerade_site() {
    [[ "${HY2_MODE}" != "masquerade" && -d "${MASQUERADE_DIR}" ]] || return 0
    case "${MASQUERADE_DIR}" in
        "${MIHOMO_DIR}/masquerade") rm -rf -- "${MASQUERADE_DIR}" ;;
        *)
            err "拒绝删除异常的静态网页目录：${MASQUERADE_DIR}"
            return 1
            ;;
    esac
    info "已删除未使用的本地静态网页目录"
}

read_old_hop_range() {
    local range=""
    local service_values=""
    local service_port=""

    if [[ -r "${HOP_STATE_FILE}" ]]; then
        range="$(tr -d '\r\n' < "${HOP_STATE_FILE}")"
    elif [[ -r "${CLIENT_FILE}" ]]; then
        range="$(sed -nE 's/^[[:space:]]*ports:[[:space:]]*"?([0-9]+-[0-9]+)"?[[:space:]]*$/\1/p' "${CLIENT_FILE}" | head -n1)"
    fi

    if [[ "${range}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        OLD_HOP_START="${BASH_REMATCH[1]}"
        OLD_HOP_END="${BASH_REMATCH[2]}"
        return 0
    fi

    if [[ -r "${HOP_SERVICE_FILE}" ]]; then
        service_values="$(sed -nE 's#^ExecStart=.*/mihomo-hysteria2-port-hopping\.sh start ([0-9]+) ([0-9]+) ([0-9]+)$#\1 \2 \3#p' "${HOP_SERVICE_FILE}" | head -n1)"
        if [[ -n "${service_values}" ]]; then
            read -r OLD_HOP_START OLD_HOP_END service_port <<< "${service_values}"
            return 0
        fi
    fi

    OLD_HOP_START="20000"
    OLD_HOP_END="50000"
}

read_old_port() {
    if [[ -f "${PROTOCOL_CONFIG}" ]]; then
        HAD_OLD_CONFIG=1
        OLD_PORT="$(yaml_number_field "${PROTOCOL_CONFIG}" "port" || true)"
        [[ -n "${OLD_PORT}" ]] || { err "无法读取现有 Hysteria2 监听端口"; exit 1; }
        read_old_hop_range
    fi
}

backup_configs() {
    if [[ -f "${PROTOCOL_CONFIG}" ]]; then
        PROTOCOL_BACKUP="$(mktemp /tmp/netkit-hysteria2.XXXXXX.yaml)"
        cp -a "${PROTOCOL_CONFIG}" "${PROTOCOL_BACKUP}"
    fi
    if [[ -f "${MIHOMO_CONFIG}" ]]; then
        CONFIG_BACKUP="$(mktemp /tmp/netkit-mihomo-config.XXXXXX.yaml)"
        cp -a "${MIHOMO_CONFIG}" "${CONFIG_BACKUP}"
    fi
    if [[ -f "${HOP_SERVICE_FILE}" ]]; then
        SERVICE_BACKUP="$(mktemp /tmp/netkit-hysteria2-service.XXXXXX)"
        cp -a "${HOP_SERVICE_FILE}" "${SERVICE_BACKUP}"
    fi
}

write_protocol_config() {
    local yaml_password yaml_cert yaml_key yaml_masquerade yaml_obfs_password
    yaml_password="$(yaml_quote "${PASSWORD}")"
    yaml_cert="$(yaml_quote "${CERT_FILE}")"
    yaml_key="$(yaml_quote "${KEY_FILE}")"
    yaml_masquerade="$(yaml_quote "${MASQUERADE_URL}")"
    yaml_obfs_password="$(yaml_quote "${OBFS_PASSWORD}")"

    umask 077
    mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"

    {
        echo "  - name: hysteria2-in"
        echo "    type: hysteria2"
        echo "    port: ${PORT}"
        echo "    listen: 0.0.0.0"
        echo "    users:"
        echo "      ${USERNAME}: ${yaml_password}"
        echo "    ignore-client-bandwidth: true"
        case "${HY2_MODE}" in
            masquerade)
                echo "    masquerade: ${yaml_masquerade}"
                ;;
            salamander)
                echo "    obfs: salamander"
                echo "    obfs-password: ${yaml_obfs_password}"
                echo "    masquerade: \"\""
                ;;
            *)
                echo "    masquerade: \"\""
                ;;
        esac
        echo "    alpn:"
        echo "      - h3"
        echo "    certificate: ${yaml_cert}"
        echo "    private-key: ${yaml_key}"
    } > "${PROTOCOL_CONFIG}"
    chmod 600 "${PROTOCOL_CONFIG}"
}

install_port_hopping() {
    info "配置 Hysteria2 UDP 跳跃端口 ${HOP_START}-${HOP_END}..."
    systemctl stop "${HOP_SERVICE}" >/dev/null 2>&1 || true
    mkdir -p "${HOP_DROPIN_DIR}"

    cat > "${HOP_SERVICE_FILE}" <<EOF
[Unit]
Description=Mihomo Hysteria2 UDP Port Hopping
After=network-online.target nftables.service
Before=mihomo.service
PartOf=mihomo.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${HOP_HELPER} start ${HOP_START} ${HOP_END} ${PORT}
ExecStop=/bin/bash ${HOP_HELPER} stop ${HOP_START} ${HOP_END} ${PORT}

[Install]
WantedBy=multi-user.target
EOF

    cat > "${HOP_DROPIN_FILE}" <<EOF
[Unit]
Wants=${HOP_SERVICE}
After=${HOP_SERVICE}
EOF

    chmod 644 "${HOP_SERVICE_FILE}" "${HOP_DROPIN_FILE}"
    systemctl daemon-reload
    systemctl enable "${HOP_SERVICE}" >/dev/null
    systemctl restart "${HOP_SERVICE}"
}

remove_port_hopping() {
    systemctl disable --now "${HOP_SERVICE}" >/dev/null 2>&1 || true
    bash "${HOP_HELPER}" stop "${HOP_START}" "${HOP_END}" "${PORT}" >/dev/null 2>&1 || true
    rm -f "${HOP_SERVICE_FILE}" "${HOP_DROPIN_FILE}"
    rmdir "${HOP_DROPIN_DIR}" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

restore_old_port_hopping() {
    if [[ -z "${SERVICE_BACKUP}" || ! -f "${SERVICE_BACKUP}" ]]; then
        remove_port_hopping
        return 0
    fi

    systemctl stop "${HOP_SERVICE}" >/dev/null 2>&1 || true
    cp -a "${SERVICE_BACKUP}" "${HOP_SERVICE_FILE}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "${HOP_SERVICE}" >/dev/null 2>&1 || true
    systemctl restart "${HOP_SERVICE}" >/dev/null 2>&1 || true
}

remove_hop_ufw_rule() {
    command -v ufw >/dev/null 2>&1 || return 0
    remove_ufw_port_rule "${HOP_START}:${HOP_END}" udp
}

rollback() {
    warn "正在回滚 Hysteria2 配置..."

    if [[ -n "${PROTOCOL_BACKUP}" && -f "${PROTOCOL_BACKUP}" ]]; then
        cp -a "${PROTOCOL_BACKUP}" "${PROTOCOL_CONFIG}"
    else
        rm -f "${PROTOCOL_CONFIG}"
    fi

    if [[ -n "${CONFIG_BACKUP}" && -f "${CONFIG_BACKUP}" ]]; then
        cp -a "${CONFIG_BACKUP}" "${MIHOMO_CONFIG}"
    else
        "${BUILD_CONFIG_SCRIPT}" >/dev/null 2>&1 || true
    fi

    if (( UFW_RULE_ADDED == 1 )); then
        remove_hop_ufw_rule
    fi
    if (( HAD_OLD_CONFIG == 1 )); then
        restore_old_port_hopping
    else
        remove_port_hopping
    fi

    systemctl restart mihomo >/dev/null 2>&1 || true
}

apply_config() {
    info "构建并验证 Mihomo 配置..."
    if ! "${BUILD_CONFIG_SCRIPT}"; then
        rollback
        err "Mihomo 配置验证失败，已恢复原配置"
        exit 1
    fi

    if ! install_port_hopping; then
        rollback
        err "Hysteria2 端口跳跃规则配置失败，已恢复原配置"
        exit 1
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! ufw status 2>/dev/null | grep -Fq "${HOP_START}:${HOP_END}/udp"; then
            info "放行 Hysteria2 UDP 跳跃端口 ${HOP_START}-${HOP_END}..."
            ufw allow "${HOP_START}:${HOP_END}/udp" comment "Mihomo Hysteria2 UDP Hopping" >/dev/null
            UFW_RULE_ADDED=1
        fi
    fi

    if ! systemctl restart mihomo; then
        rollback
        err "Mihomo 启动失败，已恢复原配置"
        exit 1
    fi

    if ! systemctl is-active --quiet mihomo; then
        rollback
        err "Mihomo 服务未正常运行，已恢复原配置"
        exit 1
    fi
}

remove_old_firewall_rule() {
    if [[ -n "${OLD_PORT}" ]]; then
        remove_ufw_port_rule "${OLD_PORT}" "udp"
    fi
    if [[ -n "${OLD_HOP_START}" && -n "${OLD_HOP_END}" ]] &&
       [[ "${OLD_HOP_START}-${OLD_HOP_END}" != "${HOP_START}-${HOP_END}" ]] &&
       command -v ufw >/dev/null 2>&1; then
        remove_ufw_port_rule "${OLD_HOP_START}:${OLD_HOP_END}" udp
    fi
}

write_hop_state() {
    local temp_file="${HOP_STATE_FILE}.tmp.$$"

    umask 077
    printf '%s-%s\n' "${HOP_START}" "${HOP_END}" > "${temp_file}"
    chmod 600 "${temp_file}"
    mv -f "${temp_file}" "${HOP_STATE_FILE}"
}

write_client_info() {
    local link_host=""
    local yaml_server yaml_domain yaml_password yaml_obfs_password yaml_fingerprint hy2_query hy2_link

    link_host="$(uri_host "${SERVER_IP}")"
    yaml_server="$(yaml_quote "${SERVER_IP}")"
    yaml_domain="$(yaml_quote "${DOMAIN}")"
    yaml_password="$(yaml_quote "${PASSWORD}")"
    yaml_obfs_password="$(yaml_quote "${OBFS_PASSWORD}")"
    yaml_fingerprint="$(yaml_quote "${CERT_FINGERPRINT}")"
    hy2_query="sni=${DOMAIN}&insecure=1&pinSHA256=${CERT_FINGERPRINT}"
    if [[ "${HY2_MODE}" == "salamander" ]]; then
        hy2_query+="&obfs=salamander&obfs-password=${OBFS_PASSWORD}"
    fi
    hy2_link="hysteria2://${PASSWORD}@${link_host}:${HOP_START}-${HOP_END}/?${hy2_query}"

    umask 077
    {
        echo "Hysteria2 Link:"
        echo "${hy2_link}"
        echo
        echo "Mihomo / Clash:"
        echo "- name: Mihomo Hysteria2"
        echo "  type: hysteria2"
        echo "  server: ${yaml_server}"
        echo "  port: ${PORT}"
        echo "  ports: \"${HOP_START}-${HOP_END}\""
        echo "  hop-interval: ${HOP_INTERVAL}"
        echo "  password: ${yaml_password}"
        echo "  sni: ${yaml_domain}"
        if [[ "${HY2_MODE}" == "salamander" ]]; then
            echo "  obfs: salamander"
            echo "  obfs-password: ${yaml_obfs_password}"
        fi
        echo "  skip-cert-verify: true"
        echo "  fingerprint: ${yaml_fingerprint}"
        echo "  alpn:"
        echo "    - h3"
    } > "${CLIENT_FILE}"
    chmod 600 "${CLIENT_FILE}"
}

cleanup_backups() {
    [[ -z "${PROTOCOL_BACKUP}" ]] || rm -f "${PROTOCOL_BACKUP}"
    [[ -z "${CONFIG_BACKUP}" ]] || rm -f "${CONFIG_BACKUP}"
    [[ -z "${SERVICE_BACKUP}" ]] || rm -f "${SERVICE_BACKUP}"
}

show_result() {
    local hy2_link
    local mode_text=""
    hy2_link="$(sed -n '/^Hysteria2 Link:$/ {n;p;q;}' "${CLIENT_FILE}")"

    banner "Mihomo Hysteria2 安装成功" "$GREEN"
    kv "Server IP    :" "${SERVER_IP}"
    kv "Domain       :" "${DOMAIN}"
    kv "Certificate  :" "自签证书 + SHA-256 指纹固定"
    kv "Fingerprint  :" "${CERT_FINGERPRINT}"
    kv "Hop Ports    :" "${HOP_START}-${HOP_END}/UDP"
    kv "Listen Port  :" "${PORT}/UDP"
    kv "Hop Interval :" "${HOP_INTERVAL} 秒"
    kv "Password     :" "${PASSWORD}"
    case "${HY2_MODE}" in
        masquerade)
            mode_text="HTTP/3 网站伪装"
            kv "Mode         :" "${mode_text}"
            kv "Masquerade   :" "${MASQUERADE_URL}"
            ;;
        salamander)
            mode_text="Salamander 混淆"
            kv "Mode         :" "${mode_text}"
            kv "Obfs Password:" "${OBFS_PASSWORD}"
            ;;
        *)
            kv "Mode         :" "标准 HTTP/3（返回 404）"
            ;;
    esac
    echo
    label " Hysteria2 Link"
    value "${hy2_link}"
    echo
    path_kv "主配置文件      :" "${MIHOMO_CONFIG}"
    path_kv "协议配置文件    :" "${PROTOCOL_CONFIG}"
    path_kv "连接信息文件    :" "${CLIENT_FILE}"
    path_kv "TLS 证书        :" "${CERT_FILE}"
    echo
    label " Mihomo / Clash YAML"
    echo
    sed -n '/^Mihomo \/ Clash:/,$p' "${CLIENT_FILE}" | tail -n +2 | while IFS= read -r line; do
        value "${line}"
    done
    echo
    divider "$GREEN"
}

main() {
    check_root
    banner "安装 Mihomo Hysteria2"
    install_dependencies
    check_mihomo
    get_server_ip
    prepare_self_signed_certificate
    info "自签模式使用 VPS IP 连接；SNI ${DOMAIN} 无需配置 A/AAAA 记录"
    read_old_port
    prompt_hop_range
    prompt_hy2_mode
    write_masquerade_site
    PASSWORD="$(openssl rand -hex 32)"
    backup_configs
    write_protocol_config
    apply_config
    cleanup_unused_masquerade_site
    remove_old_firewall_rule
    write_hop_state
    write_client_info
    cleanup_backups
    show_result
}

main "$@"
