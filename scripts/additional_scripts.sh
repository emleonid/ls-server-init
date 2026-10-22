#!/bin/bash

# This menu downloads privileged helper scripts. Keep the checksums in sync
# whenever one of the referenced scripts is intentionally changed.

readonly BASE_URL="https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/additional"

readonly URL_CONFIGURE_DOCKER="${BASE_URL}/configure_docker.sh"
readonly URL_CONFIGURE_DOCKER_LOGIN="${BASE_URL}/configure_docker_login.sh"
readonly URL_PATCH_CERTBOT="${BASE_URL}/patch_certbot.sh"
readonly URL_PATCH_NGINX_SSL="${BASE_URL}/patch_nginx_ssl.sh"

readonly SHA_CONFIGURE_DOCKER="d510f6eeff2bdc8c4280bd77c0fd6601111410b9bce96d0ccd5513f34ed4b9fe"
readonly SHA_CONFIGURE_DOCKER_LOGIN="c55371de6d166da2a842daeb9924564ee3c793abb7960927e1623a56266b04d8"
readonly SHA_PATCH_CERTBOT="5404b5f085d01d77bd38ee8d70bd95e5fe67295de428c1ffd378fcb9c70fc814"
readonly SHA_PATCH_NGINX_SSL="0ef829deb96db6c2e465e9613167235916ad7e82e435ffe0b49118277f5d0ec3"

# Color codes for console output
readonly RED='\033[0;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

readonly OPTIONS=(
    "1. Configure Docker (Patch)"
    "2. Configure Docker Login (Credential Store)"
    "3. Patch Certbot (standalone -> nginx)"
    "4. Patch Nginx SSL (IPv6 & HTTP 2)"
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
        printf '%b\n' "${GREEN}Additional Script Menu...${NC}"
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
                0) execute_script "$URL_CONFIGURE_DOCKER" "$SHA_CONFIGURE_DOCKER" ;;
                1) execute_script "$URL_CONFIGURE_DOCKER_LOGIN" "$SHA_CONFIGURE_DOCKER_LOGIN" ;;
                2) execute_script "$URL_PATCH_CERTBOT" "$SHA_PATCH_CERTBOT" ;;
                3) execute_script "$URL_PATCH_NGINX_SSL" "$SHA_PATCH_NGINX_SSL" ;;
                4) echo "Exiting..."; return 0 ;;
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
