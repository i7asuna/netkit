#!/usr/bin/env bash

RED="\033[91m"
GREEN="\033[92m"
YELLOW="\033[93m"
CYAN="\033[96m"
WHITE="\033[97m"
RESET="\033[0m"
INPUT_CANCEL_STATUS=10

pause(){
    echo
    read -r -p "$(prompt_text "Press Enter to continue...")"
}

info(){
    echo -e "${CYAN}==> $1${RESET}"
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

prompt_text(){
    printf "%b" "${YELLOW}$1${RESET}"
}

confirm_action(){
    local message="$1"
    local answer

    read -r -p "$(prompt_text "${message} [y/N]: ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

cancel_input(){
    [[ "$1" == "0" ]] || return 1
    warning "已取消。"
}

valid_port(){
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

valid_ufw_port_spec(){
    local spec="$1"
    local start_port end_port

    if valid_port "$spec"; then
        return 0
    fi

    if [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        start_port="${BASH_REMATCH[1]}"
        end_port="${BASH_REMATCH[2]}"
        valid_port "$start_port" && valid_port "$end_port" && (( start_port <= end_port ))
        return
    fi

    return 1
}

yaml_number_field(){
    local file="$1"
    local field="$2"

    [[ -f "$file" ]] || return 0
    sed -nE "s/^[[:space:]]*${field}:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p" "$file" | head -n1
}

remove_ufw_port_rule(){
    local port="$1"
    local protocol="$2"
    local status_output line rule_number rule_port rule_protocol
    local -a delete_rule_numbers=()

    [[ -n "$port" ]] || return 0
    valid_ufw_port_spec "$port" || return 0
    [[ "$protocol" == "tcp" || "$protocol" == "udp" ]] || return 0
    command -v ufw >/dev/null 2>&1 || return 0

    if status_output=$(ufw status numbered 2>/dev/null); then
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+(:[0-9]+)?)(/(tcp|udp))?([[:space:]]|$) ]]; then
                rule_number="${BASH_REMATCH[1]}"
                rule_port="${BASH_REMATCH[2]}"
                rule_protocol="${BASH_REMATCH[5]:-all}"
                if [[ "$rule_port" == "$port" && "$rule_protocol" == "$protocol" ]]; then
                    delete_rule_numbers+=("$rule_number")
                fi
            fi
        done <<< "$status_output"
    fi

    if (( ${#delete_rule_numbers[@]} > 0 )); then
        mapfile -t delete_rule_numbers < <(
            printf '%s\n' "${delete_rule_numbers[@]}" | sort -rn -u
        )
        for rule_number in "${delete_rule_numbers[@]}"; do
            ufw --force delete "$rule_number" >/dev/null 2>&1 || true
        done
    fi

    # UFW 未启用时 status numbered 不列出规则，保留规则文本删除作为后备。
    ufw --force delete allow "${port}/${protocol}" >/dev/null 2>&1 || true
}

port_in_use(){
    local port="$1"

    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":${port}$" && return 0
    ss -lunH 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
}

random_available_port(){
    local min_port="${1:-30000}"
    local max_port="${2:-60000}"
    local port attempts

    for (( attempts = 0; attempts < 1000; attempts++ )); do
        port=$(shuf -i "${min_port}-${max_port}" -n1)
        port_in_use "$port" || {
            printf "%s" "$port"
            return 0
        }
    done

    error "无法在 ${min_port}-${max_port} 范围内找到可用端口" >&2
    return 1
}

resolve_port(){
    local port="$1"
    local min_port="${2:-1}"
    local max_port="${3:-65535}"

    if [[ -z "$port" ]]; then
        random_available_port "$min_port" "$max_port"
        return
    fi

    if ! valid_port "$port"; then
        error "端口无效：${port}" >&2
        return 1
    fi

    if (( port < min_port || port > max_port )); then
        error "端口必须在 ${min_port}-${max_port} 范围内：${port}" >&2
        return 1
    fi

    if port_in_use "$port"; then
        error "端口已被占用：${port}" >&2
        return 1
    fi

    printf "%s" "$port"
}

uri_host(){
    local host="$1"

    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf "[%s]" "$host"
    else
        printf "%s" "$host"
    fi
}

yaml_quote(){
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

normalize_reality_sni(){
    local host="${1:-aws.amazon.com}"

    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    host="${host%/}"

    if [[ "$host" == *:* ]]; then
        error "Reality SNI 只填写域名，不要带端口：${host}" >&2
        return 1
    fi

    if [[ ! "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
        error "Reality SNI 域名无效：${host}" >&2
        return 1
    fi

    printf "%s" "$host"
}

label(){
    echo -e "${CYAN}$1${RESET}"
}

value(){
    echo -e "${WHITE} $1${RESET}"
}

path_value(){
    echo -e "${YELLOW} $1${RESET}"
}

kv(){
    local key="$1"
    local val="$2"

    echo -e "${CYAN} ${key}${RESET} ${WHITE}${val}${RESET}"
}

path_kv(){
    local key="$1"
    local val="$2"

    echo -e "${CYAN} ${key}${RESET} ${YELLOW}${val}${RESET}"
}

menu_item(){
    local num="$1"
    local text="$2"

    printf "%b%-3s%b %b%s%b\n" "$GREEN" "${num}." "$RESET" "$WHITE" "$text" "$RESET"
}

divider(){
    local color="${1:-$CYAN}"
    local char="${2:-=}"
    local width="${3:-42}"
    local line

    line=$(printf "%${width}s" "")
    line="${line// /$char}"
    echo -e "${color}${line}${RESET}"
}

trim_edges(){
    local text="$1"

    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf "%s" "$text"
}

display_width(){
    local text="$1"
    local chars=${#text}
    local bytes
    local extra=0

    bytes=$(printf "%s" "$text" | wc -c)
    bytes=${bytes//[[:space:]]/}
    if (( bytes > chars )); then
        extra=$(( (bytes - chars) / 2 ))
    fi

    echo $(( chars + extra ))
}

center_line(){
    local text
    local color="${2:-$CYAN}"
    local width="${3:-42}"
    local text_len
    local left=0
    local right=0
    local line

    text=$(trim_edges "$1")
    text_len=$(display_width "$text")
    if (( text_len >= width )); then
        line="$text"
    else
        left=$(( (width - text_len) / 2 ))
        right=$(( width - text_len - left ))
        printf -v line "%*s%s%*s" "$left" "" "$text" "$right" ""
    fi

    echo -e "${color}${line}${RESET}"
}

section(){
    local text
    local color="${2:-$CYAN}"
    local width="${3:-42}"
    local title
    local title_len
    local left=0
    local right=0
    local left_line
    local right_line
    local line

    text=$(trim_edges "$1")
    title=" ${text} "
    title_len=$(display_width "$title")
    if (( title_len >= width )); then
        line="$title"
    else
        left=$(( (width - title_len) / 2 ))
        right=$(( width - title_len - left ))
        printf -v left_line "%*s" "$left" ""
        printf -v right_line "%*s" "$right" ""
        line="${left_line// /=}${title}${right_line// /=}"
    fi

    echo -e "${color}${line}${RESET}"
}

banner(){
    local color="${2:-$CYAN}"

    echo
    divider "$color"
    center_line "$1" "$color"
    divider "$color"
    echo
}
