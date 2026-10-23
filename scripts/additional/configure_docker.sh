#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly RED='\033[0;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'
readonly INSTALLER_URL='https://raw.githubusercontent.com/emleonid/ls-server-init/dev/scripts/install_docker_compose.sh'
readonly INSTALLER_SHA256='ff626de8d4f7297b2c9a48b9c50d718bbd47a9949dae050f6a432d3321e784d7'

TEMP_FILES=()

print_info() { printf '%b\n' "${GREEN}$*${NC}"; }
print_warning() { printf '%b\n' "${YELLOW}$*${NC}"; }
print_error() { printf '%b\n' "${RED}$*${NC}" >&2; }
die() { print_error "$*"; exit 1; }

cleanup() {
    local file
    for file in "${TEMP_FILES[@]:-}"; do
        [[ -n "$file" ]] && rm -f -- "$file"
    done
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

verify_installer() {
    local path="$1"

    [[ -f "$path" && ! -L "$path" ]] || return 1
    printf '%s  %s\n' "$INSTALLER_SHA256" "$path" | sha256sum --check --status
}

download_installer() {
    local destination="$1"

    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --retry 3 \
            --proto '=https' --tlsv1.2 \
            --output "$destination" "$INSTALLER_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only --secure-protocol=TLSv1_2 \
            -O "$destination" -- "$INSTALLER_URL"
    else
        die 'Install curl or wget before running this installer.'
    fi
}

[[ -t 0 ]] || die 'This installer is interactive and requires a terminal.'
require_command bash
require_command dirname
require_command mktemp
require_command sha256sum

script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
local_installer="${script_dir}/../install_docker_compose.sh"
installer=''

if verify_installer "$local_installer"; then
    installer="$local_installer"
    print_info 'Using the verified Docker installer from this checkout.'
else
    if [[ -e "$local_installer" || -L "$local_installer" ]]; then
        print_warning 'The local Docker installer does not match the pinned version; it will not be executed by this wrapper.'
    fi
    installer="$(mktemp "${TMPDIR:-/tmp}/ls-server-init-docker.XXXXXX.sh")"
    TEMP_FILES+=("$installer")
    print_info 'Downloading the pinned Docker Engine and Compose installer...'
    download_installer "$installer"
    verify_installer "$installer" \
        || die 'Docker installer checksum verification failed; the downloaded file was not executed.'
fi

bash "$installer"

print_info 'Docker system installation and log rotation are complete.'
print_warning 'Docker registry credentials are user-specific.'
print_info 'Run configure_docker_login.sh directly as the Unix account that will use Docker or Compose.'
