#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_REPOSITORY="http://deb.xanmod.org"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_SOURCE="/etc/apt/sources.list.d/xanmod-release.list"
XANMOD_CLEANUP_LIST="/var/lib/netkit/xanmod-old-kernels.list"
XANMOD_CLEANUP_UNIT="/etc/systemd/system/netkit-xanmod-cleanup.service"
XANMOD_CLEANUP_SCRIPT="${SCRIPT_DIR}/system/xanmod-kernel-cleanup.sh"

fail(){
    error "$1"
    exit 1
}

protect_running_kernel(){
    local package
    local status

    [[ "$CURRENT_KERNEL" == *xanmod* ]] && return

    package="linux-image-${CURRENT_KERNEL}"
    status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    if [[ -z "$status" || "$status" == "not-installed" || "$status" == "config-files" ]]; then
        warning "无法定位当前运行内核的软件包 ${package}；请勿在安装完成前重启。"
        return
    fi

    apt-mark hold "$package" >/dev/null || \
        fail "无法保护当前运行内核软件包：${package}"
    info "已临时锁定当前运行内核：${package}"
}

repair_dpkg_state(){
    local audit

    audit=$(dpkg --audit 2>&1 || true)
    [[ -z "${audit//[[:space:]]/}" ]] && return

    warning "检测到 dpkg 上次操作未完成，正在自动恢复..."
    dpkg --force-confold --configure -a
}

detect_container(){
    local container=""

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        container=$(systemd-detect-virt --container 2>/dev/null || true)
        if [[ -n "$container" && "$container" != "none" ]]; then
            printf '%s' "$container"
            return 0
        fi
    fi

    if [[ -d /proc/vz && ! -d /proc/bc ]]; then
        printf '%s' "openvz"
        return 0
    fi

    return 1
}

cpu_has_flags(){
    local flags
    local flag

    flags=" $(awk -F: '/^flags[[:space:]]*:/{print $2; exit}' /proc/cpuinfo) "
    [[ -n "${flags// /}" ]] || return 1

    for flag in "$@"; do
        [[ "$flags" == *" $flag "* ]] || return 1
    done
}

detect_psabi_level(){
    local loader
    local loader_help=""

    for loader in \
        /lib64/ld-linux-x86-64.so.2 \
        /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
        if [[ -x "$loader" ]]; then
            loader_help=$($loader --help 2>/dev/null || true)
            break
        fi
    done

    if grep -q 'x86-64-v3 (supported' <<< "$loader_help"; then
        printf '%s' "3"
        return
    fi

    if grep -q 'x86-64-v2 (supported' <<< "$loader_help"; then
        printf '%s' "2"
        return
    fi

    if cpu_has_flags cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 \
        avx avx2 bmi1 bmi2 f16c fma movbe xsave && \
        { cpu_has_flags abm || cpu_has_flags lzcnt; }; then
        printf '%s' "3"
    elif cpu_has_flags cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; then
        printf '%s' "2"
    else
        printf '%s' "1"
    fi
}

check_disk_space(){
    local path="$1"
    local required_mb="$2"
    local available_mb

    available_mb=$(df -Pm "$path" | awk 'NR==2 {print $4}')
    [[ "$available_mb" =~ ^[0-9]+$ ]] || fail "无法读取 ${path} 的可用空间。"

    if (( available_mb < required_mb )); then
        fail "${path} 可用空间不足：至少需要 ${required_mb} MiB，当前 ${available_mb} MiB。"
    fi
}

package_has_candidate(){
    local package="$1"
    local candidate

    candidate=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2; exit}')
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

select_xanmod_package(){
    local level="$1"
    local package
    local candidates=()

    case "$level" in
        3) candidates=(linux-xanmod-x64v3 linux-xanmod-lts-x64v3) ;;
        2) candidates=(linux-xanmod-x64v2 linux-xanmod-lts-x64v2) ;;
        1) candidates=(linux-xanmod-lts-x64v1) ;;
        *) return 1 ;;
    esac

    for package in "${candidates[@]}"; do
        if package_has_candidate "$package"; then
            printf '%s' "$package"
            return 0
        fi
    done

    return 1
}

list_old_kernel_packages(){
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' \
            'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null |
        awk '$2 != "not-installed" && $1 !~ /xanmod/ {print $1}' |
        sort -u || true
}

purge_old_kernels(){
    local package
    local old_packages=()

    mapfile -t old_packages < <(list_old_kernel_packages)

    if (( ${#old_packages[@]} == 0 )); then
        info "未检测到需要删除的旧内核软件包。"
        return
    fi

    warning "正在直接删除所有非 XanMod 内核软件包："
    for package in "${old_packages[@]}"; do
        value "$package"
    done

    apt-mark unhold "${old_packages[@]}" >/dev/null 2>&1 || true
    apt-get -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confold \
        purge -y --allow-change-held-packages -- "${old_packages[@]}"
}

schedule_old_kernel_cleanup(){
    local package
    local old_packages=()

    command -v systemctl >/dev/null 2>&1 || \
        fail "系统没有 systemctl，无法安排重启后的安全内核清理。"
    [[ -r "$XANMOD_CLEANUP_SCRIPT" ]] || \
        fail "缺少旧内核清理脚本：${XANMOD_CLEANUP_SCRIPT}"

    mapfile -t old_packages < <(list_old_kernel_packages)
    if (( ${#old_packages[@]} == 0 )); then
        info "未检测到需要删除的旧内核软件包。"
        return
    fi

    mkdir -p "$(dirname "$XANMOD_CLEANUP_LIST")"
    printf '%s\n' "${old_packages[@]}" > "$XANMOD_CLEANUP_LIST"
    chmod 0600 "$XANMOD_CLEANUP_LIST"

    cat > "$XANMOD_CLEANUP_UNIT" <<EOF
[Unit]
Description=NetKit XanMod old kernel cleanup
After=local-fs.target
ConditionPathExists=${XANMOD_CLEANUP_LIST}

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${XANMOD_CLEANUP_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable netkit-xanmod-cleanup.service

    warning "旧内核不会在当前会话删除。首次成功启动 XanMod 后将自动静默清理："
    for package in "${old_packages[@]}"; do
        value "$package"
    done
}

[[ $EUID -eq 0 ]] || fail "请使用 root 用户运行。"
[[ -r /etc/os-release ]] || fail "无法识别当前系统。"

# shellcheck disable=SC1091
source /etc/os-release

OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
CODENAME="${VERSION_CODENAME:-}"
ARCH=$(uname -m)
DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || true)
CURRENT_KERNEL=$(uname -r)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
export UCF_FORCE_CONFFOLD=1


[[ "$ARCH" == "x86_64" && "$DPKG_ARCH" == "amd64" ]] || \
    fail "XanMod 官方仓库仅支持 64 位 x86（amd64）；当前架构：${ARCH}/${DPKG_ARCH:-unknown}。"

if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" && " $OS_LIKE " != *" debian "* ]]; then
    fail "仅支持使用 APT 的 Debian/Ubuntu 系发行版；当前系统：${PRETTY_NAME:-$OS_ID}。"
fi

[[ -n "$CODENAME" ]] || fail "无法读取发行版代号 VERSION_CODENAME。"

case "$CODENAME" in
    bookworm|trixie|forky|sid|noble|plucky|questing|resolute|stonking|faye|gigi|wilma|xia|zara|zena) ;;
    *) fail "XanMod 官方仓库暂不支持发行版代号：${CODENAME}。" ;;
esac

if CONTAINER=$(detect_container); then
    fail "检测到 ${CONTAINER} 容器环境，容器无法自行替换宿主机内核。"
fi

if command -v mokutil >/dev/null 2>&1 && \
    mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    fail "检测到 Secure Boot 已开启，XanMod 内核可能无法通过启动验证，请先关闭 Secure Boot。"
fi

PSABI_LEVEL=$(detect_psabi_level)
EXPECTED_PACKAGE="linux-xanmod-x64v${PSABI_LEVEL}"
if [[ "$PSABI_LEVEL" == "1" || "$CODENAME" == "bookworm" || "$CODENAME" == "faye" ]]; then
    EXPECTED_PACKAGE="linux-xanmod-lts-x64v${PSABI_LEVEL}"
fi

check_disk_space / 1024
if [[ $(df -P /boot | awk 'NR==2 {print $1}') != $(df -P / | awk 'NR==2 {print $1}') ]]; then
    check_disk_space /boot 300
fi

banner "安装 XanMod 内核（BBRv3）" "$YELLOW"
kv "系统          :" "${PRETTY_NAME:-$OS_ID} (${CODENAME})"
kv "CPU 架构      :" "$ARCH"
kv "CPU 指令级别  :" "x86-64-v${PSABI_LEVEL}"
kv "当前内核      :" "$CURRENT_KERNEL"
kv "预选软件包    :" "$EXPECTED_PACKAGE"

warning "安装新内核存在启动失败风险，请先确认服务商支持自定义内核并备份重要数据。"
warning "首次成功启动 XanMod 后会自动静默删除全部非 XanMod 内核，之后无法从旧内核回退。"
warning "若重启后没有进入 XanMod，清理服务不会删除现有内核。"
warning "NVIDIA、OpenZFS、VirtualBox 等 DKMS 模块可能不兼容。"
info "此功能只替换内核，不修改 BBR/FQ；请在重启后使用“系统调优”启用。"

protect_running_kernel
repair_dpkg_state
info "正在安装仓库依赖..."
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold \
    install -y ca-certificates wget gnupg

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

info "正在添加 XanMod 官方仓库密钥..."
wget -qO "${TEMP_DIR}/archive.key" "$XANMOD_KEY_URL"
gpg --batch --yes --dearmor \
    --output "${TEMP_DIR}/xanmod-archive-keyring.gpg" \
    "${TEMP_DIR}/archive.key"
mkdir -p /etc/apt/keyrings
install -m 0644 "${TEMP_DIR}/xanmod-archive-keyring.gpg" "$XANMOD_KEYRING"

cat > "$XANMOD_SOURCE" <<EOF
deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPOSITORY} ${CODENAME} main
EOF

info "正在刷新 XanMod 软件包索引..."
apt-get -o DPkg::Lock::Timeout=300 update

XANMOD_PACKAGE=$(select_xanmod_package "$PSABI_LEVEL") || \
    fail "仓库中没有适合 x86-64-v${PSABI_LEVEL} 的 XanMod 内核包。"

info "正在安装 ${XANMOD_PACKAGE}..."
apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold \
    install -y "$XANMOD_PACKAGE"

if ! compgen -G '/boot/vmlinuz-*xanmod*' >/dev/null; then
    fail "未在 /boot 检测到 XanMod 内核，已停止删除旧内核。"
fi

if ! compgen -G '/boot/initrd.img-*xanmod*' >/dev/null; then
    fail "未在 /boot 检测到 XanMod initrd，已停止删除旧内核。"
fi

if [[ "$CURRENT_KERNEL" == *xanmod* ]]; then
    purge_old_kernels
else
    schedule_old_kernel_cleanup
fi

if command -v update-grub >/dev/null 2>&1; then
    info "正在更新 GRUB 启动项..."
    update-grub
fi

banner "XanMod 内核替换完成" "$GREEN"
kv "已安装软件包:" "$XANMOD_PACKAGE"
kv "当前运行内核:" "$CURRENT_KERNEL"
if [[ "$CURRENT_KERNEL" == *xanmod* ]]; then
    info "非 XanMod 内核已静默删除。"
else
    info "旧内核清理已安排在首次成功启动 XanMod 后自动执行。"
fi
info "请重启后执行 uname -r，确认输出包含 xanmod。"
info "确认新内核启动成功后，再从“系统调优”选择 BBR 并应用。"
