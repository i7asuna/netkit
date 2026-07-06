#!/usr/bin/env bash

RED="\033[91m"
GREEN="\033[92m"
YELLOW="\033[93m"
CYAN="\033[96m"
WHITE="\033[97m"
RESET="\033[0m"

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

    echo -e "${GREEN}${num}.${RESET} ${WHITE}${text}${RESET}"
}

menu_action(){
    local text="$1"

    echo -e "${WHITE}${text}${RESET}"
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
    local text="$1"
    local color="${2:-$CYAN}"
    local width="${3:-42}"
    local text_len
    local left=0
    local right=0
    local line

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
    local text="$1"
    local color="${2:-$CYAN}"
    local width="${3:-42}"
    local title=" ${text} "
    local title_len
    local left=0
    local right=0
    local left_line
    local right_line
    local line

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
    echo -e "${color}$1${RESET}"
    divider "$color"
    echo
}
