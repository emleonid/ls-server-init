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

readonly SHA_VM_INIT="5667aa1aaa923c5360c082f4c96b3a2dd34d34f016b7e634bfd907c8913d94f1"
readonly SHA_POSTGRESQL="7d44e45e6e95fd70aa69d84e8220c799c141c3f94173dc3e69e2164dbbc87dfa"
readonly SHA_RABBITMQ="f2aa5cf59492a1adc13c58e30ac7a01d84c7f36b5bd6ed36ce2024e56ed5e545"
readonly SHA_DOCKER="7f0f0e66ce952cfdfec5cc600c2c0b8e2328f49bdae9a69a700121c342224b80"
readonly SHA_NGINX="111c5211cac8483f9fa1f4a29947381ef4bf9e1e8768e6a0055411fcb4f48bc2"
readonly SHA_NGINX_SSL="15f417549c365165c7e1cb52378aa9d444eda41602dc17a13131673d9460b826"
readonly SHA_FAIL2BAN="48f28b110104200f0ecb11c2eb8fca049ee2eeaf4ce8e709b4c9901407094163"
readonly SHA_SCRIPTS="9d0a0f387732bd893483926124d02b825cea6ef189b3200359cc3b0d1d399b68"

# Color codes for console output
readonly RED='\033[0;31m'
readonly GREEN='\033[1;32m'
readonly NC='\033[0m'

readonly OPTIONS=(
    "1. Server VM Initialization"
    "2. Install PostgreSQL 16 (TLS-hardened)"
    "3. Install RabbitMQ (TLS-hardened)"
    "4. Install Docker Engine and Compose"
    "5. Install and configure Nginx"
    "6. Configure HTTPS with Certbot"
    "7. Configure Fail2Ban for SSH"
    "8. Additional repair scripts"
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
