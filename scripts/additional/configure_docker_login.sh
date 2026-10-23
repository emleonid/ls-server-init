#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_info { echo -e "${GREEN}$1${NC}"; }
function print_warning { echo -e "${YELLOW}$1${NC}"; }
function print_error { echo -e "${RED}$1${NC}"; }

SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        print_error "This script needs sudo for apt and /usr/local/bin."
        exit 1
    fi
fi

print_info "======================================="
print_info "  Docker Login with Credential Store  "
print_info "======================================="

if ! command -v docker >/dev/null 2>&1; then
    print_error "Docker is not installed or not in PATH."
    exit 1
fi

REGISTRY=""
CONFIG_MODE="credsStore"

while true; do
    print_info "Select registry to log in:"
    echo "1) Docker Hub (docker.io)"
    echo "2) Custom registry"
    read -p "Choose [1-2]: " registry_choice

    case "$registry_choice" in
        1)
            REGISTRY=""
            CONFIG_MODE="credsStore"
            break
            ;;
        2)
            read -p "Enter registry hostname (example: registry.example.com:5000): " REGISTRY
            if [ -z "$REGISTRY" ]; then
                print_error "Registry hostname cannot be empty."
                continue
            fi

            while true; do
                print_info "Select credential configuration:"
                echo "1) Global store (credsStore) - recommended"
                echo "2) Registry-specific helper (credHelpers) for $REGISTRY"
                read -p "Choose [1-2]: " config_choice
                case "$config_choice" in
                    1)
                        CONFIG_MODE="credsStore"
                        break
                        ;;
                    2)
                        CONFIG_MODE="credHelpers"
                        break
                        ;;
                    *)
                        print_error "Invalid choice. Please select 1 or 2."
                        ;;
                esac
            done
            break
            ;;
        *)
            print_error "Invalid choice. Please select 1 or 2."
            ;;
    esac
done

print_info "Installing credential store dependencies..."
$SUDO apt-get update -qq
$SUDO apt-get install -y gnupg2 pass wget jq pinentry-tty

CRED_HELPER_VERSION="v0.9.4"
CRED_HELPER_URL="https://github.com/docker/docker-credential-helpers/releases/download/${CRED_HELPER_VERSION}/docker-credential-pass-${CRED_HELPER_VERSION}.linux-amd64"
CRED_HELPER_SHA256="cd1cf468c9773baab8e87047456a9b2ebbd1881952fde40fe1122fce8ae38d09"
BIN_PATH="/usr/local/bin/docker-credential-pass"

if [ -f "$BIN_PATH" ]; then
    print_info "Credential helper already exists at $BIN_PATH"
else
    print_info "Downloading docker-credential-pass ($CRED_HELPER_VERSION)..."
    if ! command -v sha256sum >/dev/null 2>&1; then
        print_error "sha256sum is required to validate the download."
        exit 1
    fi

    TMP_BIN=$(mktemp)
    wget -qO "$TMP_BIN" "$CRED_HELPER_URL"
    if ! echo "${CRED_HELPER_SHA256}  ${TMP_BIN}" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$TMP_BIN"
        print_error "Checksum validation failed for docker-credential-pass."
        exit 1
    fi

    $SUDO mv "$TMP_BIN" "$BIN_PATH"
    $SUDO chmod +x "$BIN_PATH"
    print_info "Credential helper installed."
fi

GNUPG_DIR="$HOME/.gnupg"
GPG_AGENT_CONF="$GNUPG_DIR/gpg-agent.conf"

mkdir -p "$GNUPG_DIR"
chmod 700 "$GNUPG_DIR"

PINENTRY_BIN=""
if [ -x "/usr/bin/pinentry-tty" ]; then
    PINENTRY_BIN="/usr/bin/pinentry-tty"
elif [ -x "/usr/bin/pinentry-curses" ]; then
    PINENTRY_BIN="/usr/bin/pinentry-curses"
else
    print_error "No pinentry binary found. Install pinentry-tty or pinentry-curses."
    exit 1
fi

if [ -f "$GPG_AGENT_CONF" ]; then
    if grep -q "^pinentry-program" "$GPG_AGENT_CONF"; then
        sed -i "s|^pinentry-program .*|pinentry-program $PINENTRY_BIN|" "$GPG_AGENT_CONF"
    else
        echo "pinentry-program $PINENTRY_BIN" >> "$GPG_AGENT_CONF"
    fi
else
    echo "pinentry-program $PINENTRY_BIN" > "$GPG_AGENT_CONF"
fi

chmod 600 "$GPG_AGENT_CONF"

if [ -t 0 ]; then
    export GPG_TTY=$(tty)
fi

gpgconf --kill gpg-agent >/dev/null 2>&1 || true

if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    print_warning "Headless environment detected. Pinentry is set to $PINENTRY_BIN."
    print_warning "If docker login hangs, verify pinentry can prompt in your terminal."
fi

if gpg --list-secret-keys --keyid-format=long | grep -q "^sec"; then
    print_info "GPG key found."
else
    print_warning "No GPG secret key found."
    read -p "Generate a new GPG key now? (Y/n): " generate_choice
    generate_choice=${generate_choice:-Y}
    if [[ "$generate_choice" =~ ^[Yy]$ ]]; then
        if [ ! -t 0 ]; then
            print_error "No TTY available to generate a GPG key. Run: gpg --full-generate-key"
            exit 1
        fi

        gpg --full-generate-key
    else
        print_error "GPG key is required to initialize pass."
        exit 1
    fi
fi

PASS_STORE_DIR="$HOME/.password-store"
if [ -f "$PASS_STORE_DIR/.gpg-id" ]; then
    print_info "Pass store already initialized."
else
    DEFAULT_KEY_ID=$(gpg --list-secret-keys --keyid-format=long | awk '/^sec/{split($2,a,"/"); print a[2]; exit}')
    if [ -z "$DEFAULT_KEY_ID" ]; then
        print_error "Unable to detect a GPG key ID for pass."
        exit 1
    fi

    read -p "Enter GPG key ID for pass init [${DEFAULT_KEY_ID}]: " KEY_ID
    KEY_ID=${KEY_ID:-$DEFAULT_KEY_ID}
    pass init "$KEY_ID"
    print_info "Pass store initialized."
fi

DOCKER_CONFIG_DIR="$HOME/.docker"
DOCKER_CONFIG_FILE="$DOCKER_CONFIG_DIR/config.json"
mkdir -p "$DOCKER_CONFIG_DIR"
chmod 700 "$DOCKER_CONFIG_DIR"

if [ ! -f "$DOCKER_CONFIG_FILE" ]; then
    if [ "$CONFIG_MODE" = "credsStore" ]; then
        echo '{ "credsStore": "pass" }' > "$DOCKER_CONFIG_FILE"
    else
        cat > "$DOCKER_CONFIG_FILE" <<EOF
{
  "credHelpers": {
    "$REGISTRY": "pass"
  }
}
EOF
    fi
else
    if [ "$CONFIG_MODE" = "credsStore" ]; then
        tmp=$(mktemp)
        jq '. + {"credsStore": "pass"}' "$DOCKER_CONFIG_FILE" > "$tmp" && mv "$tmp" "$DOCKER_CONFIG_FILE"
    else
        tmp=$(mktemp)
        jq --arg reg "$REGISTRY" '.credHelpers = (.credHelpers // {}) | .credHelpers[$reg] = "pass"' "$DOCKER_CONFIG_FILE" > "$tmp" && mv "$tmp" "$DOCKER_CONFIG_FILE"
    fi
fi

print_info "Docker client configured to use the pass credential store."

print_info "Starting docker login..."
if [ -z "$REGISTRY" ]; then
    docker login
else
    docker login "$REGISTRY"
fi

print_info "======================================="
print_info "  Docker Login Complete"
print_info "======================================="
