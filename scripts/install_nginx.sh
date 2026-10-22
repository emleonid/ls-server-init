#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { printf '%b\n' "${GREEN}$*${NC}"; }
print_warning() { printf '%b\n' "${YELLOW}$*${NC}" >&2; }
print_error() { printf '%b\n' "${RED}$*${NC}" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

service_enable_state() {
    systemctl is-enabled "$1" 2>/dev/null || true
}

service_is_persistently_enabled() {
    [[ "$(service_enable_state "$1")" == enabled ]]
}

require_command() {
    if ! command_exists "$1"; then
        print_error "Required command '$1' was not found."
        exit 1
    fi
}

package_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ && ${#1} -le 5 ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ipv6_is_active() {
    [[ -r /proc/net/if_inet6 ]] && grep -q '[[:xdigit:]]' /proc/net/if_inet6
}

ensure_regular_file_or_missing() {
    local path="$1"

    if [[ -L "$path" ]]; then
        print_error "Refusing to replace symbolic link: $path"
        return 1
    fi
    if [[ -e "$path" && ! -f "$path" ]]; then
        print_error "Refusing to replace a path that is not a regular file: $path"
        return 1
    fi
}

ensure_directory() {
    local path="$1"

    if [[ -L "$path" || ! -d "$path" ]]; then
        print_error "Expected a real directory at $path."
        return 1
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default_answer="$2"
    local answer=''
    local suffix='(y/N)'

    [[ "$default_answer" == yes ]] && suffix='(Y/n)'
    if ! read -r -p "$(printf '%b' "${YELLOW}${prompt} ${suffix}: ${NC}")" answer; then
        print_error "Could not read an answer from the terminal."
        return 2
    fi
    answer=${answer:-$([[ "$default_answer" == yes ]] && printf Y || printf N)}

    case "$answer" in
        [Yy]) return 0 ;;
        [Nn]) return 1 ;;
        *)
            print_error "Answer Y or N."
            return 2
            ;;
    esac
}

backup_nginx_file() {
    local source_file="$1"
    local backup_name
    local backup_path

    if [[ ! -e "$source_file" ]]; then
        return 0
    fi

    backup_name="${source_file#/etc/nginx/}"
    backup_name="${backup_name//\//-}"
    backup_path="${BACKUP_DIR}/${backup_name}.${RUN_TIMESTAMP}.bak"
    if ! cp --preserve=all -- "$source_file" "$backup_path"; then
        print_error "Could not back up $source_file."
        return 1
    fi
    printf '%s\n' "$backup_path"
}

prepare_nginx_backup_directory() {
    ensure_directory /etc/nginx
    if [[ -e "$BACKUP_DIR" || -L "$BACKUP_DIR" ]]; then
        ensure_directory "$BACKUP_DIR"
    else
        mkdir -p "$BACKUP_DIR"
    fi
    chmod 0700 "$BACKUP_DIR"
}

capture_nginx_configuration() {
    ensure_regular_file_or_missing "$NGINX_CONFIG"
    ensure_regular_file_or_missing "$PROXY_CONFIG"

    if [[ "$NGINX_CONFIG_EXISTED" != true && -f "$NGINX_CONFIG" ]]; then
        NGINX_CONFIG_EXISTED=true
        NGINX_BACKUP="$(backup_nginx_file "$NGINX_CONFIG")"
    fi
    if [[ "$PROXY_CONFIG_EXISTED" != true && -f "$PROXY_CONFIG" ]]; then
        PROXY_CONFIG_EXISTED=true
        PROXY_BACKUP="$(backup_nginx_file "$PROXY_CONFIG")"
    fi
}

install_package_start_blocker() {
    if [[ -e "$POLICY_RC_D" || -L "$POLICY_RC_D" ]]; then
        print_warning "Existing $POLICY_RC_D was preserved; package service-start policy remains under administrator control."
        return 0
    fi

    POLICY_RC_D_TMP="$(mktemp /usr/sbin/.policy-rc.d.ls-server-init.XXXXXX)"
    cat >"$POLICY_RC_D_TMP" <<'EOF'
#!/bin/sh
# Temporary ls-server-init policy: do not expose the packaged Nginx default site.
case "$1" in
    nginx|nginx.service) exit 101 ;;
    *) exit 0 ;;
esac
EOF
    chown root:root "$POLICY_RC_D_TMP"
    chmod 0755 "$POLICY_RC_D_TMP"
    mv -fT -- "$POLICY_RC_D_TMP" "$POLICY_RC_D"
    POLICY_RC_D_TMP=''
    POLICY_RC_D_CREATED=true
}

remove_package_start_blocker() {
    if [[ "$POLICY_RC_D_CREATED" == true ]]; then
        if ! rm -f -- "$POLICY_RC_D"; then
            print_error "Could not remove temporary package policy $POLICY_RC_D."
            return 1
        fi
        POLICY_RC_D_CREATED=false
    fi
}

install_runtime_nginx_mask() {
    if ! systemctl mask --runtime nginx.service; then
        print_error "Could not apply a temporary runtime mask to nginx.service."
        return 1
    fi
    NGINX_RUNTIME_MASK_CREATED=true
}

remove_runtime_nginx_mask() {
    if [[ "$NGINX_RUNTIME_MASK_CREATED" == true ]]; then
        if ! systemctl unmask --runtime nginx.service; then
            print_error "Could not remove the temporary runtime mask from nginx.service."
            return 1
        fi
        NGINX_RUNTIME_MASK_CREATED=false
    fi
}

restore_file() {
    local target="$1"
    local backup="$2"
    local existed="$3"
    local target_directory="${target%/*}"
    local target_basename="${target##*/}"
    local restore_tmp=''

    if [[ "$existed" == true ]]; then
        if [[ -z "$backup" || ! -f "$backup" ]]; then
            print_error "Cannot restore $target because its backup is unavailable."
            return 1
        fi
        if ! restore_tmp="$(mktemp "${target_directory}/.${target_basename}.restore.XXXXXX")" \
           || ! cp --preserve=all -- "$backup" "$restore_tmp" \
           || ! mv -fT -- "$restore_tmp" "$target"; then
            [[ -z "$restore_tmp" ]] || rm -f -- "$restore_tmp"
            print_error "Could not restore $target from $backup."
            return 1
        fi
    elif ! rm -f -- "$target"; then
        print_error "Could not remove newly created file $target during rollback."
        return 1
    fi

    return 0
}

uses_persistent_iptables() {
    package_installed iptables-persistent \
        && package_installed netfilter-persistent \
        && [[ -x /usr/share/netfilter-persistent/plugins.d/15-ip4tables ]]
}

has_any_persistent_firewall_package() {
    package_installed iptables-persistent || package_installed netfilter-persistent
}

rollback_live_firewall_rules() {
    local index
    local rollback_failed=false

    for (( index = ${#INSERTED_IPV6_PORTS[@]} - 1; index >= 0; index-- )); do
        if ! ip6tables -w -D INPUT -p tcp --dport "${INSERTED_IPV6_PORTS[$index]}" -j ACCEPT; then
            print_error "Could not remove the added IPv6 rule for TCP port ${INSERTED_IPV6_PORTS[$index]}."
            rollback_failed=true
        fi
    done
    for (( index = ${#INSERTED_IPV4_PORTS[@]} - 1; index >= 0; index-- )); do
        if ! iptables -w -D INPUT -p tcp --dport "${INSERTED_IPV4_PORTS[$index]}" -j ACCEPT; then
            print_error "Could not remove the added IPv4 rule for TCP port ${INSERTED_IPV4_PORTS[$index]}."
            rollback_failed=true
        fi
    done

    [[ "$rollback_failed" != true ]]
}

backup_persistent_firewall_rules() {
    if ! ensure_directory /etc/iptables; then
        return 1
    fi
    if [[ -e /etc/iptables/ls-server-init-backups || -L /etc/iptables/ls-server-init-backups ]] \
       && ! ensure_directory /etc/iptables/ls-server-init-backups; then
        return 1
    fi
    if ! mkdir -p /etc/iptables/ls-server-init-backups \
       || ! chmod 0700 /etc/iptables/ls-server-init-backups; then
        print_error "Could not prepare the persistent-firewall backup directory."
        return 1
    fi

    if ! ensure_regular_file_or_missing /etc/iptables/rules.v4 \
       || ! ensure_regular_file_or_missing /etc/iptables/rules.v6; then
        return 1
    fi

    if [[ -f /etc/iptables/rules.v4 ]]; then
        RULES_V4_EXISTED=true
        RULES_V4_BACKUP="/etc/iptables/ls-server-init-backups/rules.v4.${RUN_TIMESTAMP}.bak"
        if ! cp --preserve=all -- /etc/iptables/rules.v4 "$RULES_V4_BACKUP"; then
            print_error "Could not back up /etc/iptables/rules.v4."
            return 1
        fi
    fi
    if [[ -f /etc/iptables/rules.v6 ]]; then
        RULES_V6_EXISTED=true
        RULES_V6_BACKUP="/etc/iptables/ls-server-init-backups/rules.v6.${RUN_TIMESTAMP}.bak"
        if ! cp --preserve=all -- /etc/iptables/rules.v6 "$RULES_V6_BACKUP"; then
            print_error "Could not back up /etc/iptables/rules.v6."
            return 1
        fi
    fi
}

restore_persistent_firewall_files() {
    local rollback_failed=false

    if ! restore_file /etc/iptables/rules.v4 "$RULES_V4_BACKUP" "$RULES_V4_EXISTED"; then
        rollback_failed=true
    fi
    if ! restore_file /etc/iptables/rules.v6 "$RULES_V6_BACKUP" "$RULES_V6_EXISTED"; then
        rollback_failed=true
    fi

    [[ "$rollback_failed" != true ]]
}

allow_persistent_tcp_port() {
    local port="$1"

    if ! valid_port "$port"; then
        print_error "Invalid TCP port: $port"
        return 1
    fi

    if ! iptables -w -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        if ! iptables -w -I INPUT 1 -p tcp --dport "$port" -j ACCEPT; then
            return 1
        fi
        INSERTED_IPV4_PORTS+=("$port")
    fi

    if ipv6_is_active; then
        if ! ip6tables -w -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            if ! ip6tables -w -I INPUT 1 -p tcp --dport "$port" -j ACCEPT; then
                return 1
            fi
            INSERTED_IPV6_PORTS+=("$port")
        fi
    fi
}

configure_persistent_firewall() {
    local firewall_rollback_failed=false
    local netfilter_enable_changed=false
    local netfilter_enable_state

    require_command iptables
    require_command netfilter-persistent

    if ipv6_is_active; then
        require_command ip6tables
        if [[ ! -x /usr/share/netfilter-persistent/plugins.d/25-ip6tables ]]; then
            print_error "IPv6 is active, but the persistent IPv6 rules plugin is missing."
            return 1
        fi
    fi

    netfilter_enable_state="$(service_enable_state netfilter-persistent.service)"
    case "$netfilter_enable_state" in
        enabled|disabled) ;;
        *)
            print_error "Unsupported netfilter-persistent service state: ${netfilter_enable_state:-unknown}."
            print_error "Normalize it to enabled or disabled before changing persistent firewall rules."
            return 1
            ;;
    esac

    print_warning "Persistent iptables rules detected. Preserving that backend instead of installing or enabling UFW."
    if ! backup_persistent_firewall_rules; then
        return 1
    fi

    if ! service_is_persistently_enabled netfilter-persistent.service; then
        if ! systemctl enable netfilter-persistent.service; then
            print_error "Persistent firewall rules are installed, but netfilter-persistent could not be enabled for boot."
            return 1
        fi
        netfilter_enable_changed=true
    fi
    if ! service_is_persistently_enabled netfilter-persistent.service; then
        print_error "netfilter-persistent is not enabled, so saved rules would not survive a reboot."
        if [[ "$netfilter_enable_changed" == true ]] \
           && ! systemctl disable netfilter-persistent.service; then
            print_error "CRITICAL: netfilter-persistent could not be returned to its previous disabled state."
        fi
        return 1
    fi

    if ! allow_persistent_tcp_port 80 \
       || ! allow_persistent_tcp_port 443 \
       || ! netfilter-persistent save; then
        print_error "Could not persist the HTTP/HTTPS firewall rules; restoring the previous firewall state."
        firewall_rollback_failed=false
        if ! rollback_live_firewall_rules; then
            firewall_rollback_failed=true
        fi
        if ! restore_persistent_firewall_files; then
            firewall_rollback_failed=true
        fi
        if [[ "$firewall_rollback_failed" == true ]]; then
            print_error "CRITICAL: Automatic firewall rollback was incomplete. Compare the live rules with the backups in /etc/iptables/ls-server-init-backups."
        fi
        if [[ "$netfilter_enable_changed" == true ]] \
           && ! systemctl disable netfilter-persistent.service; then
            print_error "CRITICAL: netfilter-persistent was newly enabled and could not be returned to its previous disabled state."
        fi
        return 1
    fi

    print_info "Persistent firewall rules now allow TCP ports 80 and 443."
}

configure_public_firewall() {
    local ufw_status=''

    if uses_persistent_iptables; then
        if ! configure_persistent_firewall; then
            return 1
        fi
    elif has_any_persistent_firewall_package; then
        print_error "A partial persistent-firewall installation was detected."
        print_error "Repair iptables-persistent/netfilter-persistent before changing host firewall rules."
        return 1
    elif command_exists ufw; then
        print_info "Adding idempotent UFW rules for TCP ports 80 and 443..."
        if ! ufw allow proto tcp from any to any port 80,443; then
            print_error "UFW could not add the combined HTTP/HTTPS rule. Review 'ufw status' before retrying."
            return 1
        fi

        if ! ufw_status="$(ufw status)"; then
            print_error "UFW added the rule but its status could not be read. Review 'ufw status' manually."
            return 1
        fi
        if ! grep -q '^Status: active' <<<"$ufw_status"; then
            print_warning "UFW is installed but inactive. These rules take effect only if UFW is enabled later."
        fi
    else
        print_warning "No supported host firewall manager was found. Host firewall changes were skipped."
    fi

    print_warning "On OCI or another cloud, also allow TCP ports 80 and 443 in the VCN security list or network security group."
}

rollback_nginx_configuration() {
    local index
    local rollback_failed=false

    print_warning "Restoring the previous Nginx configuration."
    if ! restore_file "$NGINX_CONFIG" "$NGINX_BACKUP" "$NGINX_CONFIG_EXISTED"; then
        rollback_failed=true
    fi
    if ! restore_file "$PROXY_CONFIG" "$PROXY_BACKUP" "$PROXY_CONFIG_EXISTED"; then
        rollback_failed=true
    fi

    for (( index = ${#DISABLED_PATHS[@]} - 1; index >= 0; index-- )); do
        if [[ -e "${DISABLED_PATHS[$index]}" || -L "${DISABLED_PATHS[$index]}" ]]; then
            print_error "Could not restore ${DISABLED_PATHS[$index]} because that path was recreated during the transaction."
            rollback_failed=true
        elif ! mv -T -- "${DISABLED_BACKUPS[$index]}" "${DISABLED_PATHS[$index]}"; then
            print_error "Could not restore disabled path ${DISABLED_PATHS[$index]}."
            rollback_failed=true
        fi
    done

    if [[ "$NGINX_WAS_ACTIVE" != true ]] && systemctl is-active --quiet nginx; then
        if ! systemctl stop nginx; then
            print_error "Nginx started during the failed transaction and could not be stopped."
            rollback_failed=true
        fi
    fi

    if [[ "$rollback_failed" != true && "$NGINX_CONFIG_EXISTED" != true ]]; then
        if [[ "$NGINX_WAS_ACTIVE" == true ]] && ! systemctl is-active --quiet nginx; then
            print_error "The original Nginx service was active without /etc/nginx/nginx.conf and could not be restarted automatically."
            rollback_failed=true
        fi
    elif [[ "$rollback_failed" != true ]] && nginx -t; then
        if [[ "$NGINX_WAS_ACTIVE" == true ]]; then
            if systemctl is-active --quiet nginx; then
                if ! systemctl reload nginx; then
                    print_error "The previous configuration was restored, but Nginx could not be reloaded."
                    rollback_failed=true
                fi
            else
                if ! systemctl start nginx; then
                    print_error "The previous configuration was restored, but Nginx could not be restarted."
                    rollback_failed=true
                fi
            fi
        fi
    else
        if [[ "$rollback_failed" == true ]]; then
            print_error "The previous Nginx files could not be restored completely; the service was not reloaded."
        else
            print_error "The previous Nginx files were restored, but that configuration does not pass nginx -t."
            rollback_failed=true
        fi
    fi

    if [[ "$NGINX_WAS_ENABLED" == true ]]; then
        if ! service_is_persistently_enabled nginx && ! systemctl enable nginx; then
            print_error "Could not restore Nginx's enabled-at-boot state."
            rollback_failed=true
        fi
    elif systemctl is-enabled --quiet nginx && ! systemctl disable nginx; then
        print_error "Could not restore Nginx's disabled-at-boot state."
        rollback_failed=true
    fi

    if [[ "$rollback_failed" == true ]]; then
        print_error "CRITICAL: Automatic Nginx rollback was incomplete. Backups remain in $BACKUP_DIR and disabled files remain in $DISABLED_CONFIG_DIR."
        return 1
    fi

    print_warning "The previous Nginx configuration and service state were restored."
    return 0
}

CONFIG_TMP=''
PROXY_TMP=''
POLICY_RC_D=/usr/sbin/policy-rc.d
POLICY_RC_D_TMP=''
POLICY_RC_D_CREATED=false
NGINX_RUNTIME_MASK_CREATED=false
FRESH_INSTALL_PENDING=false
CONFIG_TRANSACTION_ACTIVE=false
NGINX_CONFIG=''
PROXY_CONFIG=''
NGINX_BACKUP=''
PROXY_BACKUP=''
NGINX_CONFIG_EXISTED=false
PROXY_CONFIG_EXISTED=false
NGINX_WAS_ACTIVE=false
NGINX_WAS_ENABLED=false
NGINX_ORIGINAL_ENABLE_STATE=''
RULES_V4_EXISTED=false
RULES_V6_EXISTED=false
RULES_V4_BACKUP=''
RULES_V6_BACKUP=''
declare -a DISABLED_PATHS=()
declare -a DISABLED_BACKUPS=()
declare -a INSERTED_IPV4_PORTS=()
declare -a INSERTED_IPV6_PORTS=()

cleanup() {
    local exit_code=$?

    trap - EXIT
    set +e
    [[ -z "$CONFIG_TMP" ]] || rm -f -- "$CONFIG_TMP"
    [[ -z "$PROXY_TMP" ]] || rm -f -- "$PROXY_TMP"
    [[ -z "$POLICY_RC_D_TMP" ]] || rm -f -- "$POLICY_RC_D_TMP"
    remove_package_start_blocker
    remove_runtime_nginx_mask
    if [[ "$CONFIG_TRANSACTION_ACTIVE" == true ]]; then
        rollback_nginx_configuration || true
    fi
    if [[ "$FRESH_INSTALL_PENDING" == true ]]; then
        if systemctl is-active --quiet nginx && ! systemctl stop nginx; then
            print_error "CRITICAL: The incomplete fresh Nginx installation could not be stopped."
        fi
        if systemctl is-enabled --quiet nginx && ! systemctl disable nginx; then
            print_error "CRITICAL: The incomplete fresh Nginx installation could not be disabled."
        fi
    fi
    exit "$exit_code"
}

trap cleanup EXIT

if (( EUID != 0 )); then
    print_error "Please run this script as root."
    exit 1
fi

if [[ ! -t 0 ]]; then
    print_error "This installer is interactive. Run it from an interactive root shell."
    exit 1
fi

for required_command in apt-get dpkg dpkg-query grep cat chown chmod mkdir cp mv rm mktemp systemctl date; do
    require_command "$required_command"
done

if ! systemctl show-environment >/dev/null 2>&1; then
    print_error "A functional systemd system manager is required to install and manage Nginx."
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    print_error "Cannot determine the operating system because /etc/os-release is unavailable."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    ubuntu)
        if ! dpkg --compare-versions "${VERSION_ID:-0}" ge 20.04; then
            print_error "Ubuntu 20.04 or newer is required; detected ${VERSION_ID:-unknown}."
            exit 1
        fi
        ;;
    debian)
        if ! dpkg --compare-versions "${VERSION_ID:-0}" ge 11; then
            print_error "Debian 11 or newer is required; detected ${VERSION_ID:-unknown}."
            exit 1
        fi
        ;;
    *)
        print_error "This installer supports Ubuntu and Debian; detected '${ID:-unknown}'."
        exit 1
        ;;
esac

RUN_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ).$$"
NGINX_CONFIG=/etc/nginx/nginx.conf
PROXY_CONFIG=/etc/nginx/proxy.conf
BACKUP_DIR=/etc/nginx/ls-server-init-backups
DISABLED_CONFIG_DIR=/etc/nginx/ls-server-init-disabled
NGINX_MARKER='# Managed by ls-server-init. Re-run the installer to update this file.'

print_info "======================================="
print_info "  Starting Nginx Installation Script"
print_info "======================================="

if ask_yes_no "Allow public HTTP and HTTPS ports (80 and 443) through the host firewall?" yes; then
    OPEN_PUBLIC_PORTS=true
else
    prompt_status=$?
    if (( prompt_status == 2 )); then
        print_error "No package, firewall, or Nginx changes were made."
        exit 1
    fi
    OPEN_PUBLIC_PORTS=false
fi

if [[ -e /etc/nginx || -L /etc/nginx ]]; then
    ensure_directory /etc/nginx
    for nginx_directory in /etc/nginx/conf.d /etc/nginx/sites-enabled; do
        if [[ -e "$nginx_directory" || -L "$nginx_directory" ]]; then
            ensure_directory "$nginx_directory"
        fi
    done
fi
ensure_regular_file_or_missing "$NGINX_CONFIG"
ensure_regular_file_or_missing "$PROXY_CONFIG"

declare -a UNMANAGED_PATHS=()
if [[ -f "$NGINX_CONFIG" ]] && ! grep -Fqx -- "$NGINX_MARKER" "$NGINX_CONFIG"; then
    UNMANAGED_PATHS+=("$NGINX_CONFIG")
fi
if [[ -f "$PROXY_CONFIG" ]] && ! grep -Fqx -- "$NGINX_MARKER" "$PROXY_CONFIG"; then
    UNMANAGED_PATHS+=("$PROXY_CONFIG")
fi
for default_path in \
    /etc/nginx/conf.d/default.conf \
    /etc/nginx/sites-enabled/default \
    /etc/nginx/sites-enabled/default.conf; do
    if [[ -d "$default_path" ]]; then
        print_error "Refusing to disable a directory at $default_path."
        exit 1
    fi
    if [[ -e "$default_path" || -L "$default_path" ]]; then
        UNMANAGED_PATHS+=("$default_path (will be disabled)")
    fi
done

if (( ${#UNMANAGED_PATHS[@]} > 0 )); then
    print_warning "The following existing Nginx paths are not managed by ls-server-init:"
    printf '  - %s\n' "${UNMANAGED_PATHS[@]}" >&2
    print_warning "The main/proxy files will be replaced and listed default sites will be disabled after backups are created."
    read -r -p "$(printf '%b' "${YELLOW}Type OVERWRITE to authorize these changes: ${NC}")" overwrite_confirmation
    if [[ "$overwrite_confirmation" != OVERWRITE ]]; then
        print_error "Authorization was not provided. No package or Nginx configuration changes were made."
        exit 1
    fi
fi

if package_installed nginx \
   || command_exists nginx \
   || systemctl cat nginx.service >/dev/null 2>&1 \
   || [[ -e /etc/systemd/system/nginx.service || -L /etc/systemd/system/nginx.service ]] \
   || [[ -e /run/systemd/system/nginx.service || -L /run/systemd/system/nginx.service ]]; then
    NGINX_PACKAGE_PREEXISTING=true
else
    NGINX_PACKAGE_PREEXISTING=false
fi
if systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=true
fi
NGINX_ORIGINAL_ENABLE_STATE="$(service_enable_state nginx.service)"
case "$NGINX_ORIGINAL_ENABLE_STATE" in
    enabled)
        NGINX_WAS_ENABLED=true
        ;;
    disabled|not-found)
        ;;
    *)
        print_error "Unsupported nginx.service enable state: ${NGINX_ORIGINAL_ENABLE_STATE:-unknown}."
        print_error "Normalize it to enabled, disabled, or not-found before running this installer."
        exit 1
        ;;
esac

print_info "Refreshing package metadata and checking the Nginx transaction..."
apt-get update
APT_SIMULATION="$(DEBIAN_FRONTEND=noninteractive apt-get --simulate install nginx)"
printf '%s\n' "$APT_SIMULATION"
if grep -Eq '^Remv[[:space:]]' <<<"$APT_SIMULATION"; then
    print_error "APT proposes removing packages while installing Nginx. Refusing that transaction."
    exit 1
fi
if [[ "$NGINX_PACKAGE_PREEXISTING" == true ]] \
   && grep -Eq '^Inst[[:space:]]+nginx[^[:space:]]*[[:space:]]' <<<"$APT_SIMULATION"; then
    if ask_yes_no "APT will install or upgrade Nginx packages on this existing installation. Continue?" no; then
        :
    else
        confirmation_status=$?
        if (( confirmation_status == 2 )); then
            print_error "Could not confirm the package maintenance transaction."
        else
            print_info "Nginx package maintenance cancelled."
        fi
        exit 1
    fi
fi

if [[ -d /etc/nginx ]]; then
    prepare_nginx_backup_directory
    capture_nginx_configuration
fi

print_info "Installing Nginx from the operating-system repository..."
if [[ "$NGINX_PACKAGE_PREEXISTING" != true ]]; then
    FRESH_INSTALL_PENDING=true
    install_package_start_blocker
    install_runtime_nginx_mask
elif [[ "$NGINX_PACKAGE_PREEXISTING" == true ]]; then
    CONFIG_TRANSACTION_ACTIVE=true
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    nginx
remove_package_start_blocker
remove_runtime_nginx_mask
require_command nginx

if [[ "$NGINX_PACKAGE_PREEXISTING" != true ]] && systemctl is-active --quiet nginx; then
    print_info "Stopping the package's temporary default service before replacing its configuration..."
    systemctl stop nginx
fi

ensure_directory /etc/nginx
for nginx_directory in \
    /etc/nginx/conf.d \
    /etc/nginx/sites-enabled \
    "$BACKUP_DIR" \
    "$DISABLED_CONFIG_DIR"; do
    if [[ -e "$nginx_directory" || -L "$nginx_directory" ]]; then
        ensure_directory "$nginx_directory"
    fi
done
mkdir -p /etc/nginx/conf.d /etc/nginx/sites-enabled "$BACKUP_DIR" "$DISABLED_CONFIG_DIR"
chmod 0700 "$BACKUP_DIR" "$DISABLED_CONFIG_DIR"
for nginx_directory in \
    /etc/nginx \
    /etc/nginx/conf.d \
    /etc/nginx/sites-enabled \
    "$BACKUP_DIR" \
    "$DISABLED_CONFIG_DIR"; do
    ensure_directory "$nginx_directory"
done

ensure_regular_file_or_missing "$NGINX_CONFIG"
ensure_regular_file_or_missing "$PROXY_CONFIG"
capture_nginx_configuration

CONFIG_TMP="$(mktemp /etc/nginx/.nginx.conf.ls-server-init.XXXXXX)"
PROXY_TMP="$(mktemp /etc/nginx/.proxy.conf.ls-server-init.XXXXXX)"

cat >"$PROXY_TMP" <<'EOF'
# Managed by ls-server-init. Re-run the installer to update this file.
# If a location overrides any proxy_set_header directive, include this whole
# file in that location so Nginx does not drop the inherited proxy headers.
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
client_max_body_size 100m;
client_body_buffer_size 128k;
proxy_connect_timeout 30s;
proxy_send_timeout 90s;
proxy_read_timeout 90s;
proxy_buffers 32 4k;
EOF

cat >"$CONFIG_TMP" <<'EOF'
# Managed by ls-server-init. Re-run the installer to update this file.
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 8192;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    include /etc/nginx/proxy.conf;

    sendfile on;
    keepalive_timeout 29s;
    client_body_timeout 10s;
    client_header_timeout 10s;
    send_timeout 10s;
    server_tokens off;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1h;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

chown root:root "$CONFIG_TMP" "$PROXY_TMP"
chmod 0644 "$CONFIG_TMP" "$PROXY_TMP"

CONFIG_TRANSACTION_ACTIVE=true
mv -fT -- "$PROXY_TMP" "$PROXY_CONFIG"
PROXY_TMP=''
mv -fT -- "$CONFIG_TMP" "$NGINX_CONFIG"
CONFIG_TMP=''

for default_path in \
    /etc/nginx/conf.d/default.conf \
    /etc/nginx/sites-enabled/default \
    /etc/nginx/sites-enabled/default.conf; do
    if [[ -e "$default_path" || -L "$default_path" ]]; then
        default_label="${default_path#/etc/nginx/}"
        default_label="${default_label//\//-}"
        disabled_path="${DISABLED_CONFIG_DIR}/${default_label}.${RUN_TIMESTAMP}"
        mv -T -- "$default_path" "$disabled_path"
        DISABLED_PATHS+=("$default_path")
        DISABLED_BACKUPS+=("$disabled_path")
        print_info "Disabled the default site at $default_path (saved as $disabled_path)."
    fi
done

if ! nginx -t; then
    print_error "Nginx rejected the generated configuration."
    exit 1
fi

if ! service_is_persistently_enabled nginx; then
    systemctl enable nginx
fi

if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    systemctl start nginx
fi

if ! systemctl is-active --quiet nginx; then
    print_error "Nginx did not reach the active state."
    exit 1
fi
if ! service_is_persistently_enabled nginx; then
    print_error "Nginx is running but is not enabled for automatic startup."
    exit 1
fi

FRESH_INSTALL_PENDING=false
CONFIG_TRANSACTION_ACTIVE=false

if [[ "$OPEN_PUBLIC_PORTS" == true ]]; then
    if ! configure_public_firewall; then
        print_error "Nginx is installed and running, but host firewall configuration failed."
        exit 1
    fi
else
    print_info "Host firewall configuration skipped."
fi

print_info "Nginx is installed, validated, enabled, and running."
print_info "Create a server block with the exact public server_name before running the HTTPS helper."
print_info "Add server blocks in /etc/nginx/conf.d/ or /etc/nginx/sites-available/ and link them into /etc/nginx/sites-enabled/."
print_info "Timestamped backups and disabled default-site files were retained for recovery."
print_info "======================================="
print_info "  Nginx Installation Script Complete"
print_info "======================================="
