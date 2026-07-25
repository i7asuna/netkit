#!/usr/bin/env bash
# 为 Mihomo Hysteria2 listener 管理 UDP 端口跳跃转发规则。

set -Eeuo pipefail

ACTION="${1:-}"
RANGE_START="${2:-}"
RANGE_END="${3:-}"
TARGET_PORT="${4:-}"
RULE_COMMENT="netkit-mihomo-hysteria2-port-hopping"
NFT_FAMILY="inet"
NFT_TABLE="netkit_hysteria2"
NFT_CHAIN="prerouting"

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "必须使用 root 管理 Hysteria2 端口跳跃规则" >&2
    exit 1
fi

if [[ "${ACTION}" != "start" && "${ACTION}" != "stop" ]]; then
    echo "用法：$0 <start|stop> <起始端口> <结束端口> <监听端口>" >&2
    exit 2
fi

if ! valid_port "${RANGE_START}" || ! valid_port "${RANGE_END}" || ! valid_port "${TARGET_PORT}" ||
   (( RANGE_START > RANGE_END || TARGET_PORT < RANGE_START || TARGET_PORT > RANGE_END )); then
    echo "Hysteria2 端口跳跃参数无效" >&2
    exit 2
fi

delete_native_table() {
    if nft list table "${NFT_FAMILY}" "${NFT_TABLE}" >/dev/null 2>&1; then
        nft delete table "${NFT_FAMILY}" "${NFT_TABLE}"
    fi
}

delete_legacy_nft_rules() {
    local family handle

    for family in ip ip6; do
        while read -r handle; do
            [[ -n "${handle}" ]] || continue
            nft delete rule "${family}" nat PREROUTING handle "${handle}" >/dev/null 2>&1 || true
        done < <(
            nft -a list chain "${family}" nat PREROUTING 2>/dev/null |
                sed -nE "/comment \"${RULE_COMMENT}\".*# handle ([0-9]+)/s/.*# handle ([0-9]+).*/\1/p"
        )
    done
}

add_native_table() {
    delete_native_table

    if ! nft -f - <<EOF
table ${NFT_FAMILY} ${NFT_TABLE} {
    chain ${NFT_CHAIN} {
        type nat hook prerouting priority -100; policy accept;
        udp dport ${RANGE_START}-${RANGE_END} counter redirect to :${TARGET_PORT} comment "${RULE_COMMENT}"
    }
}
EOF
    then
        delete_native_table >/dev/null 2>&1 || true
        return 1
    fi
}

if ! command -v nft >/dev/null 2>&1; then
    echo "未找到 nft，无法管理 Hysteria2 端口跳跃" >&2
    exit 1
fi

if [[ "${ACTION}" == "start" ]]; then
    add_native_table
    delete_legacy_nft_rules
else
    delete_native_table
    delete_legacy_nft_rules
fi
