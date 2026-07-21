#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

header(){
    local title="${1:-TLS 证书申请与管理}"

    echo
    divider "$CYAN"
    center_line "$title" "$WHITE"
    divider "$CYAN"
}

ACME_HOME="/root/.acme.sh"
ACME_SH="${ACME_HOME}/acme.sh"
CF_API_BASE="https://api.cloudflare.com/client/v4"
CERT_DIR="/etc/mihomo/certs"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/private.key"
DOMAIN_FILE="${CERT_DIR}/domain"
RELOAD_CMD='if systemctl is-active --quiet mihomo 2>/dev/null; then systemctl restart mihomo; else echo "警告：Mihomo 服务不存在或未运行，证书已部署，暂不重启。"; fi'

DOMAIN=""
ROOT_DOMAIN=""
ZONE_ID=""
CF_TOKEN=""
CF_RESPONSE_FILE=""
CF_HTTP_CODE=""
CF_TEST_RECORD_ID=""
INSTALLER_FILE=""
ARCHIVE_DIR=""
ERROR_REPORTED=false
MASKED_INPUT=""

on_error(){
    local status="$1"
    local line="$2"
    local command="$3"

    if $ERROR_REPORTED; then
        return 0
    fi
    ERROR_REPORTED=true

    if [[ -n "${CF_TOKEN:-}" ]]; then
        command="${command//"$CF_TOKEN"/[REDACTED]}"
    fi
    printf '\n\033[91m证书管理失败：第 %s 行，命令：%s（退出码：%s）\033[0m\n' \
        "$line" "$command" "$status" >&2
}

cleanup(){
    local status=$?

    set +e
    if [[ -n "$CF_TEST_RECORD_ID" && -n "$ZONE_ID" && -n "$CF_TOKEN" ]]; then
        cf_api_request DELETE "zones/${ZONE_ID}/dns_records/${CF_TEST_RECORD_ID}" >/dev/null 2>&1
    fi
    [[ -n "$CF_RESPONSE_FILE" ]] && rm -f "$CF_RESPONSE_FILE"
    [[ -n "$INSTALLER_FILE" ]] && rm -f "$INSTALLER_FILE"
    CF_TOKEN=""
    unset CF_TOKEN
    return "$status"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

check_root(){
    if [[ "$EUID" -ne 0 ]]; then
        error "请使用 root 用户运行此功能。"
        exit 1
    fi

    if [[ ! -r /etc/os-release ]]; then
        error "无法识别操作系统，仅支持 Debian。"
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *debian* ]]; then
        error "当前系统不是 Debian，已停止操作。"
        exit 1
    fi
}

install_dependencies(){
    local missing=()
    local package

    for package in curl cron openssl socat ca-certificates jq; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$package")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        info "正在安装证书管理依赖：${missing[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
        info "证书管理依赖已安装。"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || {
            error "cron 服务无法启动，不能保证证书自动续期。"
            exit 1
        }
    fi
}

install_acme(){
    if [[ -x "$ACME_SH" ]]; then
        info "检测到 acme.sh，跳过重复安装。"
    else
        info "正在从 acme.sh 官方安装脚本安装 acme.sh..."
        INSTALLER_FILE=$(mktemp /tmp/get-acme.XXXXXX.sh)
        curl -fsSL --retry 3 --connect-timeout 10 https://get.acme.sh -o "$INSTALLER_FILE"
        sh "$INSTALLER_FILE"
        rm -f "$INSTALLER_FILE"
        INSTALLER_FILE=""

        if [[ ! -x "$ACME_SH" ]]; then
            error "acme.sh 安装失败。"
            exit 1
        fi
    fi

    info "正在显式设置 Let's Encrypt 为默认证书颁发机构..."
    "$ACME_SH" --set-default-ca --server letsencrypt

    info "正在确认 acme.sh 自动续期任务..."
    "$ACME_SH" --install-cronjob --home "$ACME_HOME"
}

validate_domain(){
    local domain="$1"
    local label
    local labels=()

    if [[ "${#domain}" -gt 253 || "$domain" != *.* ]]; then
        return 1
    fi
    if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
        return 1
    fi

    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        if [[ -z "$label" || "${#label}" -gt 63 || ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            return 1
        fi
    done

    [[ "${labels[-1]}" =~ ^[a-z]{2,63}$ ]]
}

prompt_domain(){
    local input

    while true; do
        read -r -p "$(prompt_text "请输入证书完整域名（输入 0 取消）: ")" input
        input=$(trim_edges "$input")
        input="${input%.}"
        input="${input,,}"

        if cancel_input "$input"; then
            return "$INPUT_CANCEL_STATUS"
        fi
        if validate_domain "$input"; then
            DOMAIN="$input"
            return 0
        fi
        error "域名格式无效。请输入不带协议、端口、路径和通配符的完整域名。"
    done
}

read_secret_masked(){
    local message="$1"
    local char

    MASKED_INPUT=""
    printf '%b' "$(prompt_text "$message")"

    while true; do
        if ! IFS= read -r -s -n 1 char; then
            echo
            return 1
        fi

        if [[ -z "$char" ]]; then
            echo
            return 0
        fi

        case "$char" in
            $'\177'|$'\b')
                if [[ -n "$MASKED_INPUT" ]]; then
                    MASKED_INPUT="${MASKED_INPUT%?}"
                    printf '\b \b'
                fi
                ;;
            *)
                MASKED_INPUT+="$char"
                printf '*'
                ;;
        esac
    done
}

prompt_token(){
    local input

    while true; do
        if ! read_secret_masked "请输入 Cloudflare API Token（输入显示为 *，输入 0 取消）: "; then
            error "读取 Cloudflare API Token 失败。"
            return 1
        fi
        input="$MASKED_INPUT"
        MASKED_INPUT=""

        if [[ "$input" == "0" ]]; then
            warning "已取消。"
            return "$INPUT_CANCEL_STATUS"
        fi
        if [[ "${#input}" -ge 20 && "${#input}" -le 256 ]] && \
           [[ "$input" =~ ^[A-Za-z0-9._-]+$ ]]; then
            CF_TOKEN="$input"
            input=""
            return 0
        fi
        input=""
        error "Token 格式无效或为空。请重新输入 Cloudflare API Token。"
    done
}

prompt_inputs(){
    prompt_domain || return $?
    prompt_token || return $?
}

cf_api_request(){
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local auth_fd
    local curl_status=0

    : > "$CF_RESPONSE_FILE"
    exec {auth_fd}<<<"header = \"Authorization: Bearer ${CF_TOKEN}\""

    if [[ -n "$data" ]]; then
        CF_HTTP_CODE=$(curl --silent --show-error --config "/dev/fd/${auth_fd}" \
            --request "$method" --header "Content-Type: application/json" \
            --connect-timeout 10 --max-time 30 --output "$CF_RESPONSE_FILE" \
            --write-out '%{http_code}' --data-binary "$data" \
            "${CF_API_BASE}/${endpoint}") || curl_status=$?
    else
        CF_HTTP_CODE=$(curl --silent --show-error --config "/dev/fd/${auth_fd}" \
            --request "$method" --header "Content-Type: application/json" \
            --connect-timeout 10 --max-time 30 --output "$CF_RESPONSE_FILE" \
            --write-out '%{http_code}' "${CF_API_BASE}/${endpoint}") || curl_status=$?
    fi

    exec {auth_fd}<&-
    return "$curl_status"
}

cloudflare_error_message(){
    jq -r '[.errors[]?.message, .messages[]?.message] | map(select(length > 0)) | join("；")' \
        "$CF_RESPONSE_FILE" 2>/dev/null || true
}

verify_cloudflare_token(){
    local api_message

    info "正在验证 Cloudflare API Token 和网络连接..."
    if ! cf_api_request GET "user/tokens/verify"; then
        error "Cloudflare API 网络连接失败，请检查服务器网络、DNS 和系统时间。"
        exit 1
    fi
    if [[ "$CF_HTTP_CODE" != "200" ]] || ! jq -e '.success == true and .result.status == "active"' \
        "$CF_RESPONSE_FILE" >/dev/null 2>&1; then
        api_message=$(cloudflare_error_message)
        error "Cloudflare API Token 无效或已失效${api_message:+：${api_message}}"
        exit 1
    fi
    success "Cloudflare API Token 有效，API 连接正常。"
}

find_zone(){
    local candidate="$DOMAIN"
    local api_message
    local found_name

    info "正在从完整域名推导并查找 Cloudflare Zone..."
    while [[ "$candidate" == *.* ]]; do
        if ! cf_api_request GET "zones?name=${candidate}&status=active&per_page=5"; then
            error "查询 Cloudflare Zone 时网络连接失败。"
            exit 1
        fi
        if [[ "$CF_HTTP_CODE" == "401" || "$CF_HTTP_CODE" == "403" ]]; then
            api_message=$(cloudflare_error_message)
            error "Cloudflare 权限不足：无法查询 Zone${api_message:+（${api_message}）}。"
            error "acme.sh 的 dns_cf 需要实际取得 Zone ID；请为对应 Zone 补充可查询 Zone 的权限后重试。"
            exit 1
        fi
        if [[ "$CF_HTTP_CODE" != "200" ]] || ! jq -e '.success == true' "$CF_RESPONSE_FILE" >/dev/null 2>&1; then
            api_message=$(cloudflare_error_message)
            error "Cloudflare Zone 查询失败${api_message:+：${api_message}}"
            exit 1
        fi

        ZONE_ID=$(jq -r '.result[0].id // empty' "$CF_RESPONSE_FILE")
        found_name=$(jq -r '.result[0].name // empty' "$CF_RESPONSE_FILE")
        if [[ -n "$ZONE_ID" && -n "$found_name" ]]; then
            ROOT_DOMAIN="$found_name"
            success "找到 Cloudflare Zone：${ROOT_DOMAIN}"
            return 0
        fi
        candidate="${candidate#*.}"
    done

    error "未找到与 ${DOMAIN} 对应的 Cloudflare Zone。"
    error "请确认 Zone 已添加到 Cloudflare，且 Token 的资源范围包含该 Zone。"
    exit 1
}

verify_cloudflare_dns_permissions(){
    local challenge_name="_acme-challenge.${DOMAIN}"
    local test_value
    local payload
    local api_message

    info "正在实际验证 DNS TXT 记录的读取、创建和删除权限..."
    if ! cf_api_request GET "zones/${ZONE_ID}/dns_records?type=TXT&name=${challenge_name}&per_page=5"; then
        error "读取 Cloudflare DNS 记录时网络连接失败。"
        exit 1
    fi
    if [[ "$CF_HTTP_CODE" != "200" ]] || ! jq -e '.success == true' "$CF_RESPONSE_FILE" >/dev/null 2>&1; then
        api_message=$(cloudflare_error_message)
        error "Cloudflare 权限不足：无法读取该 Zone 的 DNS 记录${api_message:+（${api_message}）}。"
        exit 1
    fi

    test_value="netkit-permission-test-$(openssl rand -hex 12)"
    payload=$(jq -nc --arg type "TXT" --arg name "$challenge_name" --arg content "$test_value" \
        '{type:$type,name:$name,content:$content,ttl:120}')
    if ! cf_api_request POST "zones/${ZONE_ID}/dns_records" "$payload"; then
        error "创建 Cloudflare DNS TXT 测试记录时网络连接失败。"
        exit 1
    fi

    CF_TEST_RECORD_ID=$(jq -r '.result.id // empty' "$CF_RESPONSE_FILE")
    if [[ ! "$CF_HTTP_CODE" =~ ^2[0-9]{2}$ || -z "$CF_TEST_RECORD_ID" ]] || \
       ! jq -e '.success == true' "$CF_RESPONSE_FILE" >/dev/null 2>&1; then
        api_message=$(cloudflare_error_message)
        CF_TEST_RECORD_ID=""
        error "Cloudflare 权限不足：无法创建 DNS TXT 记录${api_message:+（${api_message}）}。"
        exit 1
    fi

    if ! cf_api_request DELETE "zones/${ZONE_ID}/dns_records/${CF_TEST_RECORD_ID}"; then
        error "删除 Cloudflare DNS TXT 测试记录时网络连接失败。"
        exit 1
    fi
    if [[ ! "$CF_HTTP_CODE" =~ ^2[0-9]{2}$ ]] || ! jq -e '.success == true' "$CF_RESPONSE_FILE" >/dev/null 2>&1; then
        api_message=$(cloudflare_error_message)
        error "Cloudflare 权限不足：测试 TXT 记录已创建，但无法删除${api_message:+（${api_message}）}。"
        error "请手动删除 ${challenge_name} 中内容以 netkit-permission-test- 开头的 TXT 记录。"
        exit 1
    fi

    CF_TEST_RECORD_ID=""
    success "Cloudflare DNS TXT 记录读取、创建和删除测试均通过。"
}

check_dns_resolution(){
    local ipv4
    local ipv6

    info "正在检查 ${DOMAIN} 当前的 A / AAAA 解析..."
    ipv4=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '$2 == "STREAM" {print $1}' | sort -u || true)
    ipv6=$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '$2 == "STREAM" && $1 ~ /:/ {print $1}' | sort -u || true)

    echo
    label " A 记录"
    if [[ -n "$ipv4" ]]; then
        while IFS= read -r address; do value "$address"; done <<< "$ipv4"
    else
        warning "未查询到 A 记录。"
    fi
    echo
    label " AAAA 记录"
    if [[ -n "$ipv6" ]]; then
        while IFS= read -r address; do value "$address"; done <<< "$ipv6"
    else
        warning "未查询到 AAAA 记录。"
    fi
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        warning "没有 A/AAAA 记录不会阻止 DNS-01 申请证书。"
    fi
    warning "Hysteria2 正式连接前，${DOMAIN} 必须有指向本服务器的正确 A 或 AAAA 记录。"
}

domain_conf_path(){
    printf '%s/%s_ecc/%s.conf' "$ACME_HOME" "$1" "$1"
}

set_acme_conf_value(){
    local file="$1"
    local key="$2"
    local value="$3"
    local line
    local temp_file
    local replaced=false

    [[ "$key" =~ ^[A-Za-z0-9_]+$ ]]
    [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
    mkdir -p "$(dirname "$file")"
    touch "$file"
    chmod 600 "$file"

    temp_file=$(mktemp "${file}.XXXXXX")
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${key}="* ]]; then
            printf "%s='%s'\n" "$key" "$value" >> "$temp_file"
            replaced=true
        else
            printf '%s\n' "$line" >> "$temp_file"
        fi
    done < "$file"

    if ! $replaced; then
        printf "%s='%s'\n" "$key" "$value" >> "$temp_file"
    fi

    chmod 600 "$temp_file"
    mv -f "$temp_file" "$file"
}

save_cloudflare_credentials(){
    local conf

    conf=$(domain_conf_path "$DOMAIN")
    [[ -f "$conf" ]] || return 0
    set_acme_conf_value "$conf" "CF_Token" "$CF_TOKEN"
    set_acme_conf_value "$conf" "CF_Zone_ID" "$ZONE_ID"
    chmod 600 "$conf"
}

run_acme_allow_skip(){
    local status=0

    set +e
    "$@"
    status=$?
    set -e
    case "$status" in
        0) return 0 ;;
        2)
            info "acme.sh 检查完成：证书尚未到续期时间，未向 CA 重复申请。"
            return 0
            ;;
        *) return "$status" ;;
    esac
}

issue_certificate(){
    info "正在使用 Cloudflare DNS-01 申请 Let's Encrypt ECC P-256 证书..."
    info "此过程不会监听 80/443 端口，也不会修改 UFW。"
    if ! CF_Token="$CF_TOKEN" CF_Zone_ID="$ZONE_ID" \
        run_acme_allow_skip "$ACME_SH" --issue --server letsencrypt --dns dns_cf \
            --domain "$DOMAIN" --keylength ec-256; then
        error "证书申请失败。请检查上方 acme.sh 输出；Cloudflare 测试记录已自动清理。"
        exit 1
    fi
    save_cloudflare_credentials
}

prepare_certificate_paths(){
    install -d -m 700 "$CERT_DIR"
    [[ -e "$KEY_FILE" ]] || install -m 600 /dev/null "$KEY_FILE"
    [[ -e "$CERT_FILE" ]] || install -m 644 /dev/null "$CERT_FILE"
    chmod 700 "$CERT_DIR"
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
}

write_current_domain(){
    local temp_file

    temp_file=$(mktemp "${CERT_DIR}/.domain.XXXXXX")
    printf '%s\n' "$1" > "$temp_file"
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$DOMAIN_FILE"
}

install_certificate(){
    local domain="$1"

    prepare_certificate_paths
    info "正在使用 acme.sh --install-cert 部署证书..."
    if ! "$ACME_SH" --install-cert --domain "$domain" --ecc \
        --fullchain-file "$CERT_FILE" --key-file "$KEY_FILE" --reloadcmd "$RELOAD_CMD"; then
        error "证书部署失败。"
        return 1
    fi
    chmod 700 "$CERT_DIR"
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    write_current_domain "$domain"
}

certificate_key_match(){
    local cert_digest
    local key_digest

    cert_digest=$(openssl x509 -in "$CERT_FILE" -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)
    key_digest=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | \
        openssl dgst -sha256)
    [[ -n "$cert_digest" && "$cert_digest" == "$key_digest" ]]
}

certificate_exists(){
    [[ -r "$CERT_FILE" && -r "$KEY_FILE" ]] && \
        openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 && \
        openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1
}

current_certificate_domain(){
    local domain=""

    [[ -s "$DOMAIN_FILE" ]] && read -r domain < "$DOMAIN_FILE"
    if [[ -z "$domain" && -r "$CERT_FILE" ]]; then
        domain=$(openssl x509 -in "$CERT_FILE" -noout -subject -nameopt RFC2253 2>/dev/null | \
            sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p' | head -n1)
    fi
    printf '%s' "$domain"
}

certificate_remaining_days(){
    local not_after
    local expiry_epoch
    local now_epoch

    not_after=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2-)
    expiry_epoch=$(date -d "$not_after" +%s)
    now_epoch=$(date +%s)
    printf '%s' "$(( (expiry_epoch - now_epoch) / 86400 ))"
}

show_certificate_summary(){
    local domain issuer not_before not_after remaining

    if ! certificate_exists; then
        warning "未检测到完整、可读取的已部署证书和私钥。"
        return 1
    fi
    domain=$(current_certificate_domain)
    issuer=$(openssl x509 -in "$CERT_FILE" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
    not_before=$(openssl x509 -in "$CERT_FILE" -noout -startdate | cut -d= -f2-)
    not_after=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2-)
    remaining=$(certificate_remaining_days)

    section "当前 TLS 证书" "$YELLOW"
    echo
    kv "域名       :" "${domain:-未知}"
    kv "签发者     :" "$issuer"
    kv "生效时间   :" "$not_before"
    kv "到期时间   :" "$not_after"
    kv "剩余天数   :" "${remaining} 天"
    if certificate_key_match; then
        kv "证书/私钥  :" "匹配"
    else
        kv "证书/私钥  :" "不匹配"
    fi
}

verify_certificate(){
    local subject sans issuer not_before not_after public_algorithm curve

    info "正在验证已部署的证书和私钥..."
    [[ -r "$CERT_FILE" ]] || { error "证书文件不存在或不可读：${CERT_FILE}"; return 1; }
    [[ -r "$KEY_FILE" ]] || { error "私钥文件不存在或不可读：${KEY_FILE}"; return 1; }
    openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || {
        error "fullchain.pem 不是有效的 PEM 证书。"; return 1;
    }
    openssl pkey -in "$KEY_FILE" -check -noout >/dev/null 2>&1 || {
        error "private.key 不是有效的私钥。"; return 1;
    }
    certificate_key_match || { error "证书与私钥不匹配。"; return 1; }

    subject=$(openssl x509 -in "$CERT_FILE" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
    sans=$(openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | \
        tail -n +2 | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    issuer=$(openssl x509 -in "$CERT_FILE" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
    not_before=$(openssl x509 -in "$CERT_FILE" -noout -startdate | cut -d= -f2-)
    not_after=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2-)
    public_algorithm=$(openssl x509 -in "$CERT_FILE" -noout -text | \
        sed -n 's/^[[:space:]]*Public Key Algorithm: //p' | head -n1)
    curve=$(openssl pkey -in "$KEY_FILE" -noout -text 2>/dev/null | \
        sed -n -e 's/^[[:space:]]*ASN1 OID: //p' -e 's/^[[:space:]]*NIST CURVE: //p' | head -n1)

    banner "证书验证通过" "$GREEN"
    kv "Subject    :" "$subject"
    kv "SAN        :" "${sans:-未读取到}"
    kv "Issuer     :" "$issuer"
    kv "Not Before :" "$not_before"
    kv "Not After  :" "$not_after"
    kv "公钥算法   :" "${public_algorithm:-未知}"
    kv "ECC 曲线   :" "${curve:-未知}"
    kv "剩余天数   :" "$(certificate_remaining_days) 天"
    kv "证书/私钥  :" "匹配"
    echo
    path_kv "证书文件   :" "$CERT_FILE"
    path_kv "私钥文件   :" "$KEY_FILE"
}

show_cron_status(){
    local cron_entries

    echo
    section "acme.sh 自动续期" "$YELLOW"
    echo
    cron_entries=$(crontab -l 2>/dev/null || true)
    if grep -qE 'acme\.sh.*--cron' <<< "$cron_entries"; then
        success "acme.sh 自动续期 cron 任务已存在。"
        grep -E 'acme\.sh.*--cron' <<< "$cron_entries" | while IFS= read -r entry; do value "$entry"; done
    else
        error "未找到 acme.sh 自动续期 cron 任务。"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet cron; then
            kv "cron 服务  :" "运行中"
        else
            kv "cron 服务  :" "未运行"
        fi
    fi
}

show_hysteria2_tls_example(){
    echo
    section "Mihomo Hysteria2 Listener TLS 示例" "$YELLOW"
    echo
    value "listeners:"
    value "  - name: hy-in"
    value "    type: hysteria2"
    value "    certificate: ${CERT_FILE}"
    value "    private-key: ${KEY_FILE}"
    echo
    warning "以上 certificate/private-key 字段来自 Mihomo 当前 Hysteria2 listener 配置格式。"
}

archive_current_certificate(){
    local old_domain="$1"
    local timestamp

    [[ -r "$CERT_FILE" && -r "$KEY_FILE" ]] || return 0
    timestamp=$(date +%Y%m%d-%H%M%S)
    ARCHIVE_DIR="${CERT_DIR}/archive/${old_domain:-unknown}-${timestamp}"
    install -d -m 700 "$ARCHIVE_DIR"
    install -m 644 "$CERT_FILE" "${ARCHIVE_DIR}/fullchain.pem"
    install -m 600 "$KEY_FILE" "${ARCHIVE_DIR}/private.key"
    printf '%s\n' "$old_domain" > "${ARCHIVE_DIR}/domain"
    chmod 600 "${ARCHIVE_DIR}/domain"
    info "旧部署证书已保留到：${ARCHIVE_DIR}"
}

restore_archived_certificate(){
    [[ -n "$ARCHIVE_DIR" && -r "${ARCHIVE_DIR}/fullchain.pem" && -r "${ARCHIVE_DIR}/private.key" ]] || return 0
    install -m 644 "${ARCHIVE_DIR}/fullchain.pem" "$CERT_FILE"
    install -m 600 "${ARCHIVE_DIR}/private.key" "$KEY_FILE"
}

detach_old_deployment(){
    local old_domain="$1"
    local conf

    [[ -n "$old_domain" ]] || return 0
    conf=$(domain_conf_path "$old_domain")
    [[ -f "$conf" ]] || return 0
    sed -i -e '/^Le_RealCertPath=/d' -e '/^Le_RealCACertPath=/d' \
        -e '/^Le_RealKeyPath=/d' -e '/^Le_RealFullChainPath=/d' \
        -e '/^Le_ReloadCmd=/d' "$conf"
    chmod 600 "$conf"
    info "旧域名证书仍保留并可在 acme.sh 内续期，但已解除固定 Mihomo 路径的部署绑定。"
}

verify_cloudflare_for_domain(){
    verify_cloudflare_token
    find_zone
    verify_cloudflare_dns_permissions
    check_dns_resolution
}

configure_new_certificate(){
    local old_domain="${1:-}"

    if ! prompt_inputs; then
        return 0
    fi
    verify_cloudflare_for_domain
    [[ -n "$old_domain" ]] && archive_current_certificate "$old_domain"
    issue_certificate
    if ! install_certificate "$DOMAIN"; then
        restore_archived_certificate
        error "新证书部署失败；如有旧证书备份，固定路径已尝试恢复。"
        return 1
    fi
    if [[ -n "$old_domain" && "$old_domain" != "$DOMAIN" ]]; then
        detach_old_deployment "$old_domain"
    fi
    verify_certificate
    show_cron_status
    show_hysteria2_tls_example
}

normal_renewal_check(){
    local domain="$1"

    info "正在执行正常续期检查（不使用 --force）..."
    if ! run_acme_allow_skip "$ACME_SH" --renew --domain "$domain" --ecc; then
        error "正常续期检查失败，请查看 acme.sh 输出。"
        return 1
    fi
    verify_certificate
    show_cron_status
}

force_reissue(){
    local domain="$1"

    warning "强制重新申请会真实请求 Let's Encrypt，可能消耗 CA 频率限制。"
    if ! confirm_action "确认强制重新申请并测试完整续期、部署和重启流程吗？"; then
        warning "已取消强制重新申请。"
        return 0
    fi

    DOMAIN="$domain"
    prompt_token || return 0
    verify_cloudflare_for_domain
    save_cloudflare_credentials
    info "正在强制续期并执行完整部署流程..."
    if ! CF_Token="$CF_TOKEN" CF_Zone_ID="$ZONE_ID" \
        "$ACME_SH" --renew --domain "$domain" --ecc --force; then
        error "强制重新申请失败。"
        return 1
    fi
    save_cloudflare_credentials
    install_certificate "$domain"
    verify_certificate
    show_cron_status
}

existing_certificate_menu(){
    local domain
    local choice

    domain=$(current_certificate_domain)
    while true; do
        header "TLS 证书申请与管理"
        show_certificate_summary || true
        echo
        menu_item "1" "保留并重新部署现有证书"
        menu_item "2" "正常续期检查（不强制）"
        menu_item "3" "强制重新申请 / 测试完整续期流程"
        menu_item "4" "更换域名"
        menu_item "5" "查看详细证书与自动续期状态"
        echo
        menu_item "0" "退出"
        echo
        read -r -p "$(prompt_text "请选择: ")" choice
        choice=${choice:-0}

        case "$choice" in
            1)
                if [[ -z "$domain" ]]; then
                    error "无法确定当前证书域名，不能从 acme.sh 重新部署。"
                else
                    install_certificate "$domain" && verify_certificate
                    show_cron_status
                fi
                pause
                ;;
            2)
                if [[ -z "$domain" ]]; then error "无法确定当前证书域名。"; else normal_renewal_check "$domain"; fi
                pause
                ;;
            3)
                if [[ -z "$domain" ]]; then error "无法确定当前证书域名。"; else force_reissue "$domain"; fi
                pause
                ;;
            4)
                configure_new_certificate "$domain"
                certificate_exists && domain=$(current_certificate_domain)
                pause
                ;;
            5)
                verify_certificate || true
                show_cron_status
                show_hysteria2_tls_example
                pause
                ;;
            0) return 0 ;;
            *) error "无效选择。"; pause ;;
        esac
    done
}

show_certificate_status(){
    header "TLS 证书状态"

    if ! certificate_exists; then
        warning "未检测到已部署的 TLS 证书。"
        path_kv "证书文件   :" "$CERT_FILE"
        path_kv "私钥文件   :" "$KEY_FILE"
        show_cron_status
        return 0
    fi

    verify_certificate
    show_cron_status
}

main(){
    check_root

    if [[ "${1:-}" == "--status" ]]; then
        show_certificate_status
        return 0
    fi

    install_dependencies
    install_acme
    CF_RESPONSE_FILE=$(mktemp /tmp/netkit-cf-response.XXXXXX)

    if certificate_exists; then
        existing_certificate_menu
    else
        header "申请 TLS 证书"
        configure_new_certificate
    fi
}

main "$@"
