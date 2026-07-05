#!/usr/bin/env bash

download_remote_script(){
    local name="$1"
    local url="$2"
    local target

    target="$(mktemp "/tmp/${name}.XXXXXX.sh")"

    info "Downloading ${name}..."
    curl -fsSL -L \
        --proto '=https' \
        --tlsv1.2 \
        -o "$target" \
        "$url"

    chmod 600 "$target"
    path_kv "Downloaded script :" "$target"

    if command -v sha256sum >/dev/null 2>&1; then
        kv "SHA256            :" "$(sha256sum "$target" | awk '{print $1}')"
    fi

    warning "Please review this script before running it:"
    path_value "less $target"

    if ! confirm_action "Run downloaded ${name} script now?"; then
        warning "Cancelled. The downloaded script was kept for review:"
        path_value "$target"
        return 1
    fi

    REMOTE_SCRIPT_PATH="$target"
}

run_remote_script(){
    local name="$1"
    local url="$2"
    local status=0
    shift 2

    local REMOTE_SCRIPT_PATH=""

    download_remote_script "$name" "$url" || return 1
    bash "$REMOTE_SCRIPT_PATH" "$@" || status=$?
    rm -f "$REMOTE_SCRIPT_PATH"
    return "$status"
}
