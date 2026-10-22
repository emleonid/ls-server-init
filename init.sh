#!/bin/bash

# This menu downloads privileged helper scripts. Keep the checksums in sync
# whenever one of the referenced scripts is intentionally changed.

readonly BASE_URL="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts"

readonly URL_VM_INIT="${BASE_URL}/vm_init.sh"
readonly URL_POSTGRESQL="${BASE_URL}/install_postgresql.sh"
readonly URL_RABBITMQ="${BASE_URL}/install_rabbitmq.sh"
readonly URL_DOCKER="${BASE_URL}/install_docker_compose.sh"
readonly URL_NGINX="${BASE_URL}/install_nginx.sh"
readonly URL_NGINX_SSL="${BASE_URL}/configure_nginx_ssl.sh"
readonly URL_FAIL2BAN="${BASE_URL}/configure_fail2ban.sh"
readonly URL_SCRIPTS="${BASE_URL}/additional_scripts.sh"

readonly SHA_VM_INIT="3f5698cd7a69bf4b8cb8f43cf171e2f8689e8da0a810de754d1dc5fc74227e48"
readonly SHA_POSTGRESQL="93806c7d96e0125f3e8e815995b5452985178a86340a55e5d5a80af429569d04"
readonly SHA_RABBITMQ="b934d85c97d92280c8690c5d0972f24be640b3d164dd65211ca5dc1c062728bd"
readonly SHA_DOCKER="ae115d9a8ab543c9adbc7b72d3e36ec86ea091fa648ce6319a4e7ee3569313e4"
readonly SHA_NGINX="8f1c8a752bcb2b2e7d8d5ae32f33126803ecb57fee52204eee78cc8802ab1925"
readonly SHA_NGINX_SSL="f9e9b244f14ebc4f85b57af6125bbae593577d24e72805c28257822f92142462"
readonly SHA_FAIL2BAN="c25255ec897194bbf57b17dadd3138ee2b247dbb53d99275eff0056acc915ba2"
readonly SHA_SCRIPTS="28b7f47afb65477265d5cb9ca9f3653a15fbf7bef870dfef896d9267197a4685"

# Color codes for console output
readonly RED='\033[0;31m'
readonly GREEN='\033[1;32m'
readonly NC='\033[0m'

readonly OPTIONS=(
    "1. Server VM Initialization"
    "2. Install PostgreSQL server (VM-based)"
    "3. Install RabbitMQ server (VM-based)"
    "4. Install Docker compose setup"
    "5. Install nginx server"
    "6. Configure nginx SSL updates"
    "7. Configure fail2ban setup"
    "8. Additional scripts"
    "Exit"
)

CURRENT_TEMP_FILE=""
CURSOR_HIDDEN=false

print_error() {
    printf '%b\n' "${RED}$1${NC}" >&2
}

cleanup() {
    if [[ -n "$CURRENT_TEMP_FILE" && -f "$CURRENT_TEMP_FILE" ]]; then
        rm -f -- "$CURRENT_TEMP_FILE"
    fi

    if [[ "$CURSOR_HIDDEN" == true ]] && command -v tput >/dev/null 2>&1; then
        tput cnorm
    fi

    exec 3<&- 2>/dev/null || true
}

pause_for_menu() {
    read -r -p "Press [Enter] to return to menu." <&3
}

require_environment() {
    local command_name

    if ! { exec 3</dev/tty; } 2>/dev/null || [[ ! -t 3 ]]; then
        print_error "This menu requires an interactive terminal."
        return 1
    fi

    for command_name in wget sha256sum mktemp bash tput clear; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            print_error "Required command not found: ${command_name}"
            return 1
        fi
    done
}

execute_script() {
    local url="$1"
    local expected_sha256="$2"
    local script_name="${url##*/}"
    local exit_code=0

    if ! CURRENT_TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/ls-server-init.XXXXXX.sh"); then
        print_error "Unable to create a temporary download file."
        pause_for_menu
        return 1
    fi

    printf '%b\n' "${GREEN}Downloading ${script_name}...${NC}"
    if ! wget -q --https-only --secure-protocol=TLSv1_2 -O "$CURRENT_TEMP_FILE" -- "$url"; then
        print_error "Failed to download ${script_name}. Please check the URL or your connection."
        rm -f -- "$CURRENT_TEMP_FILE"
        CURRENT_TEMP_FILE=""
        pause_for_menu
        return 1
    fi

    if [[ ! -s "$CURRENT_TEMP_FILE" ]]; then
        print_error "Downloaded ${script_name} is empty."
        rm -f -- "$CURRENT_TEMP_FILE"
        CURRENT_TEMP_FILE=""
        pause_for_menu
        return 1
    fi

    if ! printf '%s  %s\n' "$expected_sha256" "$CURRENT_TEMP_FILE" | sha256sum --check --status; then
        print_error "Checksum verification failed for ${script_name}; it will not be executed."
        rm -f -- "$CURRENT_TEMP_FILE"
        CURRENT_TEMP_FILE=""
        pause_for_menu
        return 1
    fi

    printf '%b\n' "${GREEN}Verified ${script_name}. Executing it now...${NC}"
    if bash "$CURRENT_TEMP_FILE" <&3; then
        printf '%b\n' "${GREEN}${script_name} executed successfully.${NC}"
    else
        exit_code=$?
        print_error "${script_name} exited with status ${exit_code}."
    fi

    rm -f -- "$CURRENT_TEMP_FILE"
    CURRENT_TEMP_FILE=""
    pause_for_menu
    return "$exit_code"
}

show_menu() {
    local choice=0
    local key=""

    tput civis
    CURSOR_HIDDEN=true

    while true; do
        clear
        printf '%b\n' "${GREEN}LegioSoft Script Menu...${NC}"
        echo "Use UP and DOWN arrows to navigate and ENTER to select an option."

        for i in "${!OPTIONS[@]}"; do
            if [[ "$i" -eq "$choice" ]]; then
                printf '%b\n' "> ${GREEN}${OPTIONS[$i]}${NC}"
            else
                echo "  ${OPTIONS[$i]}"
            fi
        done

        key=""
        if ! IFS= read -rsn1 key <&3; then
            print_error "Unable to read from the terminal."
            return 1
        fi

        if [[ "$key" == $'\x1b' ]]; then
            key=""
            IFS= read -rsn2 -t 0.2 key <&3 || true
            case "$key" in
                '[A') ((choice--)) ;;
                '[B') ((choice++)) ;;
            esac
        elif [[ -z "$key" ]]; then
            case "$choice" in
                0) execute_script "$URL_VM_INIT" "$SHA_VM_INIT" ;;
                1) execute_script "$URL_POSTGRESQL" "$SHA_POSTGRESQL" ;;
                2) execute_script "$URL_RABBITMQ" "$SHA_RABBITMQ" ;;
                3) execute_script "$URL_DOCKER" "$SHA_DOCKER" ;;
                4) execute_script "$URL_NGINX" "$SHA_NGINX" ;;
                5) execute_script "$URL_NGINX_SSL" "$SHA_NGINX_SSL" ;;
                6) execute_script "$URL_FAIL2BAN" "$SHA_FAIL2BAN" ;;
                7) execute_script "$URL_SCRIPTS" "$SHA_SCRIPTS" ;;
                8) echo "Exiting..."; return 0 ;;
            esac
        fi

        ((choice < 0)) && choice=$((${#OPTIONS[@]} - 1))
        ((choice >= ${#OPTIONS[@]})) && choice=0
    done
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_environment || exit 1
show_menu
