#!/usr/bin/env bash
# nginx-listen-fix.sh — replace all listen…443 with proper IPv4+IPv6 HTTP/2 listens
# Ubuntu 24.04.1

set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

CONF_DIR=/etc/nginx/conf.d

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions for colored output
function print_info {
    echo -e "${GREEN}$1${NC}"
}

function print_warning {
    echo -e "${YELLOW}$1${NC}"
}

function print_error {
    echo -e "${RED}$1${NC}"
}

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root."
    exit 1
fi

while true; do
  FILES=( "$CONF_DIR"/*.conf )

  if (( ${#FILES[@]} == 0 )); then
    print_error "ERROR: no .conf files found in $CONF_DIR" >&2
    exit 1
  fi

  MENU=()
  for f in "${FILES[@]}"; do
    MENU+=("$f" "")
  done

  CFG=$(whiptail \
    --title "Select nginx vhost to patch listens" \
    --menu "Use ↑/↓ to select, Enter to confirm" \
    20 80 10 \
    "${MENU[@]}" \
    3>&1 1>&2 2>&3
  ) || {
    print_error "Aborted."
    exit 1
  }

  SN_LINE=$(grep -m1 -E '^\s*server_name\s+' "$CFG" || true)
  DOMAIN=$(awk '{ for(i=2;i<=NF;i++) if ($i !~ /^www\./) { gsub(/;$/,"",$i); print $i; exit } }' <<< "$SN_LINE")

  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="<unknown domain>"
  fi

  whiptail --yesno \
    "Replace all listen …443 directives in '$CFG' with proper HTTP/2 listens on IPv4 & IPv6?\n\nDetected domain: $DOMAIN" \
    12 70 \
    || { print_error "Cancelled."; exit 0; }

  BACKUP="${CFG}.bak.$(date +%Y%m%dT%H%M%S)"
  cp "$CFG" "$BACKUP"
  print_info "→ Backup saved to $BACKUP"

  TMP_FILE=$(mktemp)

  awk '
    /server\s*\{/ { in_server=1 }
    /\}/ && in_server { in_server=0 }

    in_server && /^\s*listen.*443.*;/ {
      if (!replaced[in_server]) {
        print "  listen 443 ssl http2;"
        print "  listen [::]:443 ssl http2;"
        replaced[in_server]=1
      }
      next
    }
    { print }
  ' "$CFG" > "$TMP_FILE"

  mv "$TMP_FILE" "$CFG"

  if nginx -t; then
    systemctl reload nginx
    print_info "Done! '$CFG' has updated 443 listens."
    rm -f "$BACKUP"
  else
    print_error "ERROR: nginx test failed. Check '$CFG' and '$BACKUP'"
    exit 1
  fi

  if ! whiptail --yesno "Would you like to patch another domain?" 10 60; then
    print_error "Exiting."
    exit 0
  fi
done
