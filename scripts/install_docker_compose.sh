#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly RED='\033[0;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'
readonly DOCKER_GPG_FINGERPRINT='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
readonly MAX_LOG_SIZE_MB=10240
readonly MAX_LOG_FILES=100

TEMP_FILES=()
TEMP_DIRS=()
DAEMON_CONFIG_CHANGED=false
DAEMON_CONFIG_EXISTED=false
DAEMON_CONFIG_BACKUP=''
NON_JSON_LOG_DRIVER_APPROVED=false

print_info() { printf '%b\n' "${GREEN}$*${NC}"; }
print_warning() { printf '%b\n' "${YELLOW}$*${NC}"; }
print_error() { printf '%b\n' "${RED}$*${NC}" >&2; }
die() { print_error "$*"; exit 1; }

cleanup() {
    local file dir
    for file in "${TEMP_FILES[@]:-}"; do
        [[ -n "$file" ]] && rm -f -- "$file"
    done
    for dir in "${TEMP_DIRS[@]:-}"; do
        [[ -n "$dir" && -d "$dir" ]] && rm -rf -- "$dir"
    done
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

package_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

ask_yes_no() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local answer=''
    local hint='[y/N]'

    [[ "$default_answer" == 'y' ]] && hint='[Y/n]'
    read -r -p "$(printf '%b' "${YELLOW}${prompt} ${hint}: ${NC}")" answer
    answer="${answer:-$default_answer}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

ask_positive_integer() {
    local prompt="$1"
    local default_value="$2"
    local maximum="$3"
    local answer=''
    local max_digits="${#maximum}"

    while true; do
        read -r -p "$(printf '%b' "${YELLOW}${prompt} [${default_value}]: ${NC}")" answer
        answer="${answer:-$default_value}"
        if [[ "$answer" =~ ^[0-9]+$ ]] \
            && (( ${#answer} <= max_digits )) \
            && (( 10#$answer >= 1 && 10#$answer <= maximum )); then
            printf '%s\n' "$((10#$answer))"
            return 0
        fi
        print_error "Enter a whole number from 1 to ${maximum}."
    done
}

backup_file() {
    local path="$1"
    local timestamp="$2"

    [[ -e "$path" ]] || return 0
    cp --preserve=all -- "$path" "${path}.ls-server-init.${timestamp}.bak"
}

install_docker_repository() {
    local architecture="$1"
    local codename="$2"
    local timestamp="$3"
    local key_temp exported_key_temp repo_temp gpg_home
    local -a primary_fingerprints=()
    local key_path='/etc/apt/keyrings/docker.asc'
    local repo_path='/etc/apt/sources.list.d/docker.list'

    [[ ! -L /etc/apt && -d /etc/apt ]] \
        || die 'Refusing an unexpected symbolic-link or missing /etc/apt directory.'
    [[ ! -L /etc/apt/keyrings ]] \
        || die 'Refusing symbolic-link APT keyring directory: /etc/apt/keyrings'
    [[ ! -L /etc/apt/sources.list.d && -d /etc/apt/sources.list.d ]] \
        || die 'Refusing an unexpected symbolic-link or missing /etc/apt/sources.list.d directory.'
    install -d -m 0755 /etc/apt/keyrings
    [[ ! -e "$key_path" || ( ! -L "$key_path" && -f "$key_path" ) ]] \
        || die "Docker repository key destination is symbolic or non-regular: ${key_path}"
    [[ ! -e "$repo_path" || ( ! -L "$repo_path" && -f "$repo_path" ) ]] \
        || die "Docker repository definition is symbolic or non-regular: ${repo_path}"
    key_temp="$(mktemp)"
    exported_key_temp="$(mktemp)"
    repo_temp="$(mktemp)"
    gpg_home="$(mktemp -d)"
    TEMP_FILES+=("$key_temp" "$exported_key_temp" "$repo_temp")
    TEMP_DIRS+=("$gpg_home")

    curl --fail --silent --show-error --location --retry 3 \
        --proto '=https' --tlsv1.2 \
        --output "$key_temp" \
        https://download.docker.com/linux/ubuntu/gpg
    mapfile -t primary_fingerprints < <(
        gpg --batch --show-keys --with-colons "$key_temp" \
            | awk -F: '$1 == "pub" { want_fingerprint=1; next } want_fingerprint && $1 == "fpr" { print $10; want_fingerprint=0 }'
    )
    (( ${#primary_fingerprints[@]} == 1 )) \
        || die 'Docker repository key download did not contain exactly one primary key.'
    [[ "${primary_fingerprints[0]}" == "$DOCKER_GPG_FINGERPRINT" ]] \
        || die "Docker repository signing-key fingerprint mismatch (received ${primary_fingerprints[0]:-none})."

    gpg --batch --quiet --homedir "$gpg_home" --import "$key_temp"
    gpg --batch --quiet --homedir "$gpg_home" --armor \
        --export "$DOCKER_GPG_FINGERPRINT" > "$exported_key_temp"
    [[ -s "$exported_key_temp" ]] || die 'Unable to export the pinned Docker repository key.'

    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$architecture" "$key_path" "$codename" > "$repo_temp"

    if [[ ! -f "$key_path" ]] || ! cmp -s "$exported_key_temp" "$key_path"; then
        backup_file "$key_path" "$timestamp"
        install -m 0644 -o root -g root "$exported_key_temp" "$key_path"
    fi
    if [[ ! -f "$repo_path" ]] || ! cmp -s "$repo_temp" "$repo_path"; then
        backup_file "$repo_path" "$timestamp"
        install -m 0644 -o root -g root "$repo_temp" "$repo_path"
    fi
}

preflight_docker_daemon() {
    local log_size_mb="$1"
    local config_file='/etc/docker/daemon.json'
    local existing_log_driver

    [[ ! -L "$config_file" ]] || die "Refusing symbolic-link Docker daemon configuration: ${config_file}"
    [[ ! -e "$config_file" || -f "$config_file" ]] \
        || die "Docker daemon configuration is not a regular file: ${config_file}"
    [[ -e "$config_file" ]] || return 0

    jq -e 'type == "object"' "$config_file" >/dev/null 2>&1 \
        || die "${config_file} must contain one valid JSON object; no Docker packages were changed."
    jq -e '((has("log-driver") | not) or (."log-driver" | type == "string" and length > 0))
        and ((has("log-opts") | not) or (."log-opts" | type == "object"))' \
        "$config_file" >/dev/null 2>&1 \
        || die "${config_file} has invalid log-driver or log-opts values; no Docker packages were changed."
    existing_log_driver="$(
        jq -r 'if has("log-driver") and (."log-driver" | type) == "string" then ."log-driver" else empty end' \
            "$config_file"
    )"
    if [[ -n "$existing_log_driver" && "$existing_log_driver" != 'json-file' ]]; then
        print_warning "The current default Docker log driver is '${existing_log_driver}'."
        print_warning 'Its driver-specific log options will be replaced with json-file rotation settings.'
        ask_yes_no "Replace it with json-file so the ${log_size_mb} MB rotation limit can be enforced?" 'n' \
            || die 'The existing log driver was left unchanged; no Docker packages were changed.'
        NON_JSON_LOG_DRIVER_APPROVED=true
    fi
}

configure_docker_daemon() {
    local timestamp="$1"
    local log_size_mb="$2"
    local log_max_files="$3"
    local config_dir='/etc/docker'
    local config_file='/etc/docker/daemon.json'
    local source_file temp_file existing_log_driver
    local max_size="${log_size_mb}m"
    local reset_log_opts=false

    install -d -m 0755 "$config_dir"
    [[ ! -L "$config_file" ]] || die "Refusing symbolic-link Docker daemon configuration: ${config_file}"
    [[ ! -e "$config_file" || -f "$config_file" ]] \
        || die "Docker daemon configuration is not a regular file: ${config_file}"
    if [[ -e "$config_file" ]]; then
        jq -e 'type == "object"' "$config_file" >/dev/null 2>&1 \
            || die "${config_file} must contain one valid JSON object; it was not changed."
        source_file="$config_file"
        existing_log_driver="$(
            jq -r 'if has("log-driver") and (."log-driver" | type) == "string" then ."log-driver" else empty end' \
                "$source_file"
        )"
        if [[ -n "$existing_log_driver" && "$existing_log_driver" != 'json-file' ]]; then
            [[ "$NON_JSON_LOG_DRIVER_APPROVED" == true ]] \
                || die 'The default Docker log driver changed after preflight; the daemon configuration was left unchanged.'
            reset_log_opts=true
        fi
    else
        source_file="$(mktemp)"
        TEMP_FILES+=("$source_file")
        printf '%s\n' '{}' > "$source_file"
    fi

    temp_file="$(mktemp "${config_dir}/.daemon.json.XXXXXX")"
    TEMP_FILES+=("$temp_file")
    jq --arg max_size "$max_size" --arg max_files "$log_max_files" \
        --argjson reset_log_opts "$reset_log_opts" '
        if (has("log-opts") and (."log-opts" | type) != "object") then
            error("log-opts must be a JSON object")
        else
            ."data-root" = (."data-root" // "/var/lib/docker")
            | ."log-driver" = "json-file"
            | ."log-opts" = (
                if $reset_log_opts then
                    {"max-size": $max_size, "max-file": $max_files}
                else
                    ((."log-opts" // {}) + {"max-size": $max_size, "max-file": $max_files})
                end
            )
        end
    ' "$source_file" > "$temp_file" \
        || die "Unable to merge settings into ${config_file}; the existing file was not changed."

    dockerd --validate --config-file="$temp_file" >/dev/null \
        || die 'dockerd rejected the proposed daemon configuration; the existing file was not changed.'

    if [[ -f "$config_file" ]] && cmp -s "$temp_file" "$config_file"; then
        print_info 'Docker daemon configuration is already current.'
        return 0
    fi

    if [[ -e "$config_file" ]]; then
        DAEMON_CONFIG_EXISTED=true
        DAEMON_CONFIG_BACKUP="${config_file}.ls-server-init.${timestamp}.bak"
        backup_file "$config_file" "$timestamp"
    fi
    chmod 0644 "$temp_file"
    chown root:root "$temp_file"
    mv -fT -- "$temp_file" "$config_file"
    DAEMON_CONFIG_CHANGED=true
    print_info 'Docker daemon configuration was merged and validated.'
}

rollback_docker_daemon() {
    local config_file='/etc/docker/daemon.json'
    local restore_temp

    if [[ "$DAEMON_CONFIG_EXISTED" == true && -n "$DAEMON_CONFIG_BACKUP" ]]; then
        if [[ ! -f "$DAEMON_CONFIG_BACKUP" ]]; then
            print_error "Docker daemon backup is missing: ${DAEMON_CONFIG_BACKUP}"
            return 1
        fi
        if ! restore_temp="$(mktemp '/etc/docker/.daemon.json.rollback.XXXXXX')"; then
            print_error 'Unable to create a temporary file for Docker daemon rollback.'
            return 1
        fi
        TEMP_FILES+=("$restore_temp")
        if ! cp --preserve=all -- "$DAEMON_CONFIG_BACKUP" "$restore_temp"; then
            print_error 'Unable to stage the previous Docker daemon configuration.'
            return 1
        fi
        if ! mv -fT -- "$restore_temp" "$config_file"; then
            print_error 'Unable to restore the previous Docker daemon configuration.'
            return 1
        fi
        if ! cmp -s -- "$DAEMON_CONFIG_BACKUP" "$config_file"; then
            print_error 'Docker daemon rollback verification failed.'
            return 1
        fi
    else
        if ! rm -f -- "$config_file"; then
            print_error 'Unable to remove the newly created Docker daemon configuration.'
            return 1
        fi
        if [[ -e "$config_file" || -L "$config_file" ]]; then
            print_error 'Docker daemon rollback verification failed; daemon.json still exists.'
            return 1
        fi
    fi
    return 0
}

valid_project_parent() {
    local path="$1"

    [[ "$path" == /* ]] || return 1
    [[ "$path" != '/' ]] || return 1
    case "$path" in
        /boot|/dev|/etc|/proc|/sys|/usr|/var/lib/docker|/boot/*|/dev/*|/etc/*|/proc/*|/sys/*|/usr/*|/var/lib/docker/*)
            return 1
            ;;
    esac
    return 0
}

path_has_symlink_component() {
    local path="$1"
    local current='/' component
    local -a components=()

    IFS='/' read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        if [[ "$current" == '/' ]]; then
            current="/${component}"
        else
            current="${current}/${component}"
        fi
        [[ ! -L "$current" ]] || return 0
    done
    return 1
}

path_is_root_controlled() {
    local path="$1"
    local owner mode

    owner="$(stat -c '%u' -- "$path")"
    mode="$(stat -c '%a' -- "$path")"
    [[ "$owner" == '0' ]] && (( (8#$mode & 0022) == 0 ))
}

existing_directory_chain_is_safe() {
    local path="$1"
    local current='/' component
    local -a components=()

    path_is_root_controlled / || return 1
    IFS='/' read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        if [[ "$current" == '/' ]]; then
            current="/${component}"
        else
            current="${current}/${component}"
        fi
        [[ -e "$current" ]] || break
        [[ -d "$current" && ! -L "$current" ]] || return 1
        path_is_root_controlled "$current" || return 1
    done
}

prepare_project_parent() {
    local path="$1"

    path_has_symlink_component "$path" \
        && die "Project parent ${path} contains a symbolic-link component; choose a direct path."
    existing_directory_chain_is_safe "$path" \
        || die "Every existing component of ${path} must be a root-owned directory that is not writable by group or others."

    if [[ ! -e "$path" ]]; then
        install -d -m 0755 -o root -g root "$path"
    fi

    [[ -d "$path" && ! -L "$path" ]] || die "Project parent ${path} is not a regular directory."
    [[ "$(realpath -e -- "$path")" == "$path" ]] \
        || die "Project parent ${path} did not resolve to the validated path."
    existing_directory_chain_is_safe "$path" \
        || die "Project parent ${path} is not safely controlled by root."
}

assert_safe_optional_directory() {
    local path="$1"

    [[ ! -L "$path" ]] || die "Refusing symbolic-link directory: ${path}"
    [[ -e "$path" ]] || return 0
    [[ -d "$path" ]] || die "Expected a directory but found another file type: ${path}"
    path_is_root_controlled "$path" \
        || die "Existing directory ${path} must be root-owned and not writable by group or others."
}

assert_safe_optional_file() {
    local path="$1"

    [[ ! -L "$path" ]] || die "Refusing symbolic-link file: ${path}"
    [[ -e "$path" ]] || return 0
    [[ -f "$path" ]] || die "Expected a regular file but found another file type: ${path}"
    path_is_root_controlled "$path" \
        || die "Existing file ${path} must be root-owned and not writable by group or others."
}

valid_project_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]
}

valid_image_reference() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*$ ]]
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

create_compose_project() {
    local timestamp="$1"
    local project_parent project_name project_path env_file compose_file compose_temp
    local node image
    local -a node_names=()
    local -a image_names=()

    while true; do
        read -r -p "$(printf '%b' "${YELLOW}Absolute parent directory for projects [/srv]: ${NC}")" project_parent
        project_parent="$(realpath -ms -- "${project_parent:-/srv}")"
        valid_project_parent "$project_parent" && break
        print_error 'Choose a dedicated absolute path such as /srv or /opt/apps, not a system directory.'
    done

    while true; do
        read -r -p "$(printf '%b' "${YELLOW}Project name (lowercase): ${NC}")" project_name
        valid_project_name "$project_name" && break
        print_error 'Use lowercase letters, digits, dots, underscores, or hyphens; start with a letter or digit.'
    done

    project_path="${project_parent%/}/${project_name}"
    env_file="${project_path}/.env"
    compose_file="${project_path}/docker-compose.yml"

    print_info "Add Compose services. Type 'done' after at least one service."
    while true; do
        read -r -p "$(printf '%b' "${YELLOW}Service name (or done): ${NC}")" node
        [[ "$node" == 'done' ]] && break
        if ! valid_project_name "$node"; then
            print_error 'Invalid service name. Use lowercase letters, digits, dots, underscores, or hyphens.'
            continue
        fi
        if array_contains "$node" "${node_names[@]:-}"; then
            print_error "Service ${node} was already added."
            continue
        fi
        while true; do
            read -r -p "$(printf '%b' "${YELLOW}Container image for ${node} (example: nginx:stable-alpine): ${NC}")" image
            valid_image_reference "$image" && break
            print_error 'Enter a non-empty OCI image reference without spaces or shell/YAML metacharacters.'
        done
        node_names+=("$node")
        image_names+=("$image")
    done

    if (( ${#node_names[@]} == 0 )); then
        print_warning 'No services were supplied; no project files or directories were written.'
        return 0
    fi
    if [[ -e "$compose_file" ]] && ! ask_yes_no "Replace existing ${compose_file} after making a backup?" 'n'; then
        die 'Existing Compose file was left unchanged.'
    fi

    prepare_project_parent "$project_parent"
    assert_safe_optional_directory "$project_path"
    assert_safe_optional_file "$env_file"
    assert_safe_optional_file "$compose_file"

    install -d -m 0750 -o root -g root "$project_path"
    if [[ ! -e "$env_file" ]]; then
        install -m 0600 -o root -g root /dev/null "$env_file"
    else
        chmod 0600 "$env_file"
        chown root:root "$env_file"
        print_warning "Keeping existing ${env_file}."
    fi

    compose_temp="$(mktemp "${project_path}/.docker-compose.XXXXXX.yml")"
    TEMP_FILES+=("$compose_temp")
    printf '%s\n' 'services:' > "$compose_temp"
    for index in "${!node_names[@]}"; do
        node="${node_names[$index]}"
        image="${image_names[$index]}"
        {
            printf '  %s:\n' "$node"
            printf '    image: "%s"\n' "$image"
            printf '%s\n' '    restart: unless-stopped'
        } >> "$compose_temp"
    done

    docker compose --env-file "$env_file" -f "$compose_temp" config --quiet \
        || die 'Docker Compose rejected the generated project; the existing Compose file was not changed.'
    backup_file "$compose_file" "$timestamp"
    chmod 0640 "$compose_temp"
    chown root:root "$compose_temp"
    mv -fT -- "$compose_temp" "$compose_file"

    print_info "Validated Compose project written to ${compose_file}."
    print_info "Environment file: ${env_file}"
    print_warning 'No containers were started. Review the file before running docker compose up.'
}

[[ "$EUID" -eq 0 ]] || die 'Run this script as root (sudo -i, then run it again).'
[[ -t 0 ]] || die 'This installer is interactive and requires a terminal.'
for required in apt-get awk cmp cp dpkg dpkg-query gpg grep install jq mktemp mv realpath stat systemctl; do
    command -v "$required" >/dev/null 2>&1 || {
        [[ "$required" == 'gpg' || "$required" == 'jq' ]] && continue
        die "Required command not found: ${required}"
    }
done

[[ -r /etc/os-release ]] || die 'Cannot identify this operating system.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == 'ubuntu' ]] || die 'This installer supports Ubuntu only.'
[[ -n "${VERSION_CODENAME:-}" ]] || die 'Ubuntu VERSION_CODENAME is missing.'

architecture="$(dpkg --print-architecture)"
case "$architecture" in
    amd64|arm64) ;;
    *) die "Docker packages are not supported by this script on architecture ${architecture}." ;;
esac

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
conflicting_packages=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
installed_conflicts=()
docker_transaction=("${docker_packages[@]}")
docker_preexisting=false

if command -v docker >/dev/null 2>&1; then
    docker_preexisting=true
fi
for package in "${docker_packages[@]}"; do
    if package_installed "$package"; then
        docker_preexisting=true
    fi
done
for package in "${conflicting_packages[@]}"; do
    if package_installed "$package"; then
        installed_conflicts+=("$package")
        docker_transaction+=("${package}-")
        docker_preexisting=true
    fi
done

print_info 'Installing Docker from its signed official Ubuntu repository...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg jq
for required in curl gpg jq; do require_command "$required"; done
log_size_mb="$(ask_positive_integer "Maximum size of each container log file in MB (1-${MAX_LOG_SIZE_MB})" 100 "$MAX_LOG_SIZE_MB")"
log_max_files="$(ask_positive_integer "Maximum rotated log files per container (1-${MAX_LOG_FILES})" 3 "$MAX_LOG_FILES")"
print_info "Docker will retain approximately $((log_size_mb * log_max_files)) MB of JSON logs per container (${log_max_files} files of ${log_size_mb} MB)."
print_warning 'The daemon default applies only to containers created after this change; recreate existing containers to adopt it.'
preflight_docker_daemon "$log_size_mb"
install_docker_repository "$architecture" "$VERSION_CODENAME" "$timestamp"
apt-get update
print_info 'APT simulation for the Docker package transaction:'
simulation_output="$(
    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get --simulate install "${docker_transaction[@]}"
)" || die 'APT could not produce a safe Docker package plan; no Docker package transaction was run.'
printf '%s\n' "$simulation_output"
simulation_has_removals=false
if grep -q '^Remv ' <<< "$simulation_output"; then
    simulation_has_removals=true
fi
if (( ${#installed_conflicts[@]} > 0 )); then
    print_warning 'Conflicting packages scheduled for removal:'
    printf '  - %s\n' "${installed_conflicts[@]}"
fi
if [[ "$docker_preexisting" == true || "$simulation_has_removals" == true ]]; then
    if [[ "$docker_preexisting" == true ]]; then
        print_warning 'An existing Docker or conflicting container-runtime installation was detected.'
    fi
    if [[ "$simulation_has_removals" == true ]]; then
        print_warning 'The shown APT transaction removes one or more installed packages.'
    fi
    print_warning 'Package changes and Docker daemon restarts can interrupt running workloads.'
    ask_yes_no 'Proceed with this maintenance window and run exactly the shown package transaction?' 'n' \
        || die 'Docker packages and the Docker service were left unchanged. The signed repository configuration may have been refreshed.'
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y "${docker_transaction[@]}"

require_command docker
require_command dockerd
systemctl enable docker
configure_docker_daemon "$timestamp" "$log_size_mb" "$log_max_files"
if [[ "$DAEMON_CONFIG_CHANGED" == true ]]; then
    if ! systemctl restart docker; then
        print_error 'Docker failed to start with the new configuration; restoring the previous daemon.json.'
        rollback_docker_daemon \
            || die "Docker failed and ${DAEMON_CONFIG_BACKUP:-the previous daemon configuration} could not be restored."
        systemctl restart docker || true
        die 'Docker daemon configuration was rolled back. Inspect systemctl status docker and journalctl -u docker.'
    fi
else
    systemctl restart docker \
        || die 'Docker could not be restarted with the validated daemon settings. Inspect systemctl status docker and journalctl -u docker.'
fi

daemon_healthy=true
effective_log_driver=''
systemctl is-active --quiet docker || daemon_healthy=false
docker info >/dev/null 2>&1 || daemon_healthy=false
if [[ "$daemon_healthy" == true ]]; then
    effective_log_driver="$(docker info --format '{{.LoggingDriver}}' 2>/dev/null)" \
        || daemon_healthy=false
fi
if [[ "$daemon_healthy" != true ]]; then
    if [[ "$DAEMON_CONFIG_CHANGED" == true ]]; then
        print_error 'Docker did not become healthy with the new configuration; restoring the previous daemon.json.'
        rollback_docker_daemon \
            || die "Docker is unhealthy and ${DAEMON_CONFIG_BACKUP:-the previous daemon configuration} could not be restored."
        systemctl restart docker || true
    fi
    die 'Docker is installed but its service is not healthy. Inspect systemctl status docker and journalctl -u docker.'
fi
if [[ "$effective_log_driver" != 'json-file' ]]; then
    if [[ "$DAEMON_CONFIG_CHANGED" == true ]]; then
        print_error "Docker started with unexpected default log driver '${effective_log_driver:-unknown}'; restoring the previous daemon.json."
        rollback_docker_daemon \
            || die "Docker selected the wrong log driver and ${DAEMON_CONFIG_BACKUP:-the previous daemon configuration} could not be restored."
        systemctl restart docker || true
    fi
    die "Docker did not activate the configured json-file log driver (reported '${effective_log_driver:-unknown}')."
fi
docker compose version >/dev/null \
    || die 'Docker Engine is running, but the Docker Compose plugin could not be executed.'

print_warning 'A full OS upgrade was not run. Apply operating-system upgrades in a separate maintenance window.'
if ask_yes_no 'Create a minimal starter Docker Compose project now?' 'n'; then
    create_compose_project "$timestamp"
else
    print_info 'Skipped starter Compose project creation.'
fi

print_info 'Docker Engine and the Compose plugin are installed and configured.'
print_warning 'Registry credentials are per-user and were not changed by this root-level installer.'
print_info 'Run the Docker Login credential helper directly as the Unix account that will run docker pull or docker compose.'
