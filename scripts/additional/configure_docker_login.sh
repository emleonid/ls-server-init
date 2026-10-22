#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly RED='\033[0;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'
readonly CRED_HELPER_VERSION='v0.9.12'
readonly DOCKER_HUB_CONFIG_KEY='https://index.docker.io/v1/'

TEMP_FILES=()
SYSTEM_TEMP_FILES=()
SUDO=()
HELPER_ASSET=''
HELPER_SHA256=''
DOCKER_CONFIG_ORIGINAL_EXISTED=false
DOCKER_CONFIG_SNAPSHOT=''
DOCKER_CONFIG_BACKUP=''
DOCKER_CONFIG_TRANSACTION_READY=false
PRESERVE_CONFIG_SNAPSHOT=false
CURRENT_USER=''
CURRENT_UID=''
GPG_HOME=''
PASS_STORE_DIR=''
DOCKER_CONFIG_DIR=''
DOCKER_CONFIG_FILE=''
TARGET_CONFIG_KEY=''

print_info() { printf '%b\n' "${GREEN}$*${NC}"; }
print_warning() { printf '%b\n' "${YELLOW}$*${NC}"; }
print_error() { printf '%b\n' "${RED}$*${NC}" >&2; }
die() { print_error "$*"; exit 1; }

cleanup() {
    local exit_code=$?
    local file

    trap - EXIT
    if [[ "${DOCKER_CONFIG_TRANSACTION_READY:-false}" == true ]] \
        && declare -F rollback_docker_client >/dev/null 2>&1; then
        if rollback_docker_client; then
            print_warning 'The previous Docker client configuration was restored after an incomplete login.'
            print_warning 'Only config.json can be rolled back safely; Docker may already have created or replaced the selected encrypted pass entry.'
        else
            PRESERVE_CONFIG_SNAPSHOT=true
            if [[ -n "$DOCKER_CONFIG_SNAPSHOT" ]]; then
                print_error "Automatic Docker configuration rollback failed. Recover it from ${DOCKER_CONFIG_SNAPSHOT}."
            else
                print_error "Automatic Docker configuration rollback failed. Inspect or remove ${DOCKER_CONFIG_FILE} manually."
            fi
        fi
    fi

    for file in "${SYSTEM_TEMP_FILES[@]:-}"; do
        [[ -n "$file" ]] && "${SUDO[@]}" rm -f -- "$file" >/dev/null 2>&1 || true
    done
    for file in "${TEMP_FILES[@]:-}"; do
        if [[ "$PRESERVE_CONFIG_SNAPSHOT" == true && -n "$DOCKER_CONFIG_SNAPSHOT" && "$file" == "$DOCKER_CONFIG_SNAPSHOT" ]]; then
            continue
        fi
        [[ -n "$file" ]] && rm -f -- "$file" >/dev/null 2>&1 || true
    done
    exit "$exit_code"
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

normalize_absolute_directory() {
    local label="$1"
    local path="$2"

    [[ -n "$path" && "$path" == /* ]] || die "${label} must be an absolute path."
    while [[ "$path" != '/' && "$path" == */ ]]; do
        path="${path%/}"
    done
    [[ "$path" != '/' ]] || die "${label} must not be the filesystem root."
    [[ "$path" != *'//'*
        && "$path" != *'/./'* && "$path" != */.
        && "$path" != *'/../'* && "$path" != */..
        && "$path" != *$'\n'* && "$path" != *$'\r'* ]] \
        || die "${label} must be a normalized absolute path without dot segments or control characters."
    printf '%s\n' "$path"
}

assert_safe_directory_path() {
    local path="$1"
    local label="$2"
    local probe="$path"

    while [[ "$probe" != '/' ]]; do
        [[ ! -L "$probe" ]] || die "Refusing ${label} because a path component is a symbolic link: ${probe}"
        [[ ! -e "$probe" || -d "$probe" ]] \
            || die "Refusing ${label} because a path component is not a directory: ${probe}"
        probe="${probe%/*}"
        [[ -n "$probe" ]] || probe='/'
    done

    if [[ -e "$path" ]]; then
        [[ "$(stat -c '%u' -- "$path")" == "$CURRENT_UID" ]] \
            || die "${label} is not owned by ${CURRENT_USER}: ${path}"
    fi
}

prepare_private_directory() {
    local path="$1"
    local label="$2"

    assert_safe_directory_path "$path" "$label"
    install -d -m 0700 -- "$path"
    [[ ! -L "$path" && -d "$path" ]] || die "Unable to create a safe ${label}: ${path}"
    [[ "$(stat -c '%u' -- "$path")" == "$CURRENT_UID" ]] \
        || die "${label} is not owned by ${CURRENT_USER}: ${path}"
    chmod 0700 -- "$path"
}

valid_registry() {
    local registry="$1"
    local port=''

    [[ "$registry" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?$ ]] || return 1
    if [[ "$registry" =~ :([0-9]{1,5})$ ]]; then
        port="${BASH_REMATCH[1]}"
        (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    fi
}

canonical_registry_key() {
    local registry="${1,,}"

    case "$registry" in
        docker.io|index.docker.io)
            printf '%s\n' "$DOCKER_HUB_CONFIG_KEY"
            ;;
        *)
            printf '%s\n' "$registry"
            ;;
    esac
}

backup_user_file() {
    local path="$1"
    local timestamp="$2"
    local backup="${path}.ls-server-init.${timestamp}.bak"

    [[ -e "$path" ]] || return 0
    [[ ! -L "$path" && -f "$path" ]] || die "Refusing to back up a symbolic link or non-regular file: ${path}"
    [[ ! -e "$backup" && ! -L "$backup" ]] || die "Backup path already exists: ${backup}"
    cp --preserve=all -- "$path" "$backup"
    chmod 0600 -- "$backup"
}

credential_helper_details() {
    local architecture="$1"

    case "$architecture" in
        amd64)
            HELPER_ASSET='docker-credential-pass-v0.9.12.linux-amd64'
            HELPER_SHA256='0369caf75820b2a927b8f7435cdd6b447583e0bb30f2b0633ed83f24b4d59a37'
            ;;
        arm64)
            HELPER_ASSET='docker-credential-pass-v0.9.12.linux-arm64'
            HELPER_SHA256='cbebaeba45523050a75beabd4fd0dc7267ab095b02961940e41e6fc38d6b3ee0'
            ;;
        *)
            die "docker-credential-pass ${CRED_HELPER_VERSION} is not pinned by this script for architecture ${architecture}."
            ;;
    esac
}

verify_installed_helper() {
    local bin_path="$1"
    local resolved current_sha owner_group mode

    [[ ! -L "$bin_path" && -f "$bin_path" && -x "$bin_path" ]] \
        || die "Credential helper is not a regular executable: ${bin_path}"
    current_sha="$(sha256sum "$bin_path" | awk '{print $1}')"
    [[ "$current_sha" == "$HELPER_SHA256" ]] \
        || die "Installed credential helper checksum does not match ${CRED_HELPER_VERSION}."
    owner_group="$(stat -c '%u:%g' -- "$bin_path")"
    mode="$(stat -c '%a' -- "$bin_path")"
    [[ "$owner_group" == '0:0' && "$mode" == '755' ]] \
        || die "Credential helper must be owned by root:root with mode 0755: ${bin_path}"

    hash -r
    resolved="$(command -v docker-credential-pass 2>/dev/null || true)"
    [[ "$resolved" == "$bin_path" ]] || {
        if [[ -n "$resolved" ]]; then
            die "Docker would execute ${resolved}, not the verified helper at ${bin_path}. Remove the PATH conflict and retry."
        fi
        die "${bin_path} is not available through PATH. Add /usr/local/bin to PATH and retry."
    }
}

install_credential_helper() {
    local timestamp="$1"
    local architecture url download_file current_sha backup install_temp
    local bin_path='/usr/local/bin/docker-credential-pass'

    architecture="$(dpkg --print-architecture)"
    credential_helper_details "$architecture"
    url="https://github.com/docker/docker-credential-helpers/releases/download/${CRED_HELPER_VERSION}/${HELPER_ASSET}"

    [[ ! -L "$bin_path" ]] || die "Refusing symbolic-link credential helper destination: ${bin_path}"
    [[ ! -e "$bin_path" || -f "$bin_path" ]] \
        || die "Credential helper destination is not a regular file: ${bin_path}"

    if [[ -f "$bin_path" ]]; then
        current_sha="$("${SUDO[@]}" sha256sum "$bin_path" | awk '{print $1}')"
        if [[ "$current_sha" == "$HELPER_SHA256" ]]; then
            "${SUDO[@]}" chown root:root -- "$bin_path"
            "${SUDO[@]}" chmod 0755 -- "$bin_path"
            verify_installed_helper "$bin_path"
            print_info "Verified docker-credential-pass ${CRED_HELPER_VERSION}; no download needed."
            return 0
        fi

        backup="${bin_path}.ls-server-init.${timestamp}.bak"
        [[ ! -e "$backup" && ! -L "$backup" ]] || die "Backup path already exists: ${backup}"
        print_warning 'The installed credential helper does not match the pinned release; backing it up before replacement.'
        "${SUDO[@]}" cp --preserve=all -- "$bin_path" "$backup"
    fi

    download_file="$(mktemp)"
    TEMP_FILES+=("$download_file")
    curl --fail --silent --show-error --location --retry 3 \
        --proto '=https' --tlsv1.2 \
        --output "$download_file" "$url"
    printf '%s  %s\n' "$HELPER_SHA256" "$download_file" | sha256sum --check --status \
        || die 'Checksum validation failed for docker-credential-pass; it was not installed.'

    install_temp="$("${SUDO[@]}" mktemp "${bin_path}.ls-server-init.XXXXXX")" \
        || die 'Unable to create a same-directory credential-helper staging file.'
    SYSTEM_TEMP_FILES+=("$install_temp")
    "${SUDO[@]}" install -m 0755 -o root -g root -- "$download_file" "$install_temp"
    [[ "$(sha256sum "$install_temp" | awk '{print $1}')" == "$HELPER_SHA256" ]] \
        || die 'Staged credential-helper checksum validation failed.'
    "${SUDO[@]}" mv -fT -- "$install_temp" "$bin_path"
    verify_installed_helper "$bin_path"
    print_info "Installed verified docker-credential-pass ${CRED_HELPER_VERSION} for ${architecture}."
}

configure_pinentry() {
    local timestamp="$1"
    local agent_config="${GPG_HOME}/gpg-agent.conf"
    local pinentry_bin temp_file

    if [[ -x /usr/bin/pinentry-tty ]]; then
        pinentry_bin='/usr/bin/pinentry-tty'
    elif [[ -x /usr/bin/pinentry-curses ]]; then
        pinentry_bin='/usr/bin/pinentry-curses'
    else
        die 'No terminal pinentry program is installed.'
    fi

    prepare_private_directory "$GPG_HOME" 'GnuPG home directory'
    [[ ! -L "$agent_config" ]] || die "Refusing symbolic-link GnuPG agent configuration: ${agent_config}"
    [[ ! -e "$agent_config" || -f "$agent_config" ]] \
        || die "GnuPG agent configuration is not a regular file: ${agent_config}"

    temp_file="$(mktemp "${GPG_HOME}/.gpg-agent.conf.XXXXXX")"
    TEMP_FILES+=("$temp_file")
    if [[ -e "$agent_config" ]]; then
        awk '!/^[[:space:]]*pinentry-program[[:space:]]/' "$agent_config" > "$temp_file"
    fi
    printf 'pinentry-program %s\n' "$pinentry_bin" >> "$temp_file"

    if [[ ! -f "$agent_config" ]] || ! cmp -s "$temp_file" "$agent_config"; then
        backup_user_file "$agent_config" "$timestamp"
        chmod 0600 -- "$temp_file"
        mv -fT -- "$temp_file" "$agent_config"
    else
        chmod 0600 -- "$agent_config"
    fi

    export GPG_TTY="$(tty)"
    gpgconf --kill gpg-agent >/dev/null 2>&1 || true
}

key_has_usable_encryption() {
    local fingerprint="$1"

    gpg --batch --with-colons --list-secret-keys -- "$fingerprint" 2>/dev/null \
        | awk -F: '$1 == "sec" { if ($2 !~ /[rdei]/ && $12 ~ /[eE]/) found=1; exit } END { exit(found ? 0 : 1) }'
}

resolve_secret_key_fingerprint() {
    local selector="$1"
    local listing
    local -a fingerprints=()

    listing="$(gpg --batch --with-colons --list-secret-keys -- "$selector" 2>/dev/null)" || return 1
    mapfile -t fingerprints < <(
        printf '%s\n' "$listing" \
            | awk -F: '$1 == "sec" { want=1; next } want && $1 == "fpr" { print $10; want=0 }'
    )
    [[ "${#fingerprints[@]}" -eq 1 ]] || return 1
    key_has_usable_encryption "${fingerprints[0]}" || return 1
    printf '%s\n' "${fingerprints[0]}"
}

first_usable_secret_fingerprint() {
    local fingerprint

    while IFS= read -r fingerprint; do
        if [[ -n "$fingerprint" ]] && key_has_usable_encryption "$fingerprint"; then
            printf '%s\n' "$fingerprint"
            return 0
        fi
    done < <(
        gpg --batch --with-colons --list-secret-keys 2>/dev/null \
            | awk -F: '$1 == "sec" { want=1; next } want && $1 == "fpr" { print $10; want=0 }'
    )
    return 1
}

validate_pass_recipients() {
    local gpg_id_file="${PASS_STORE_DIR}/.gpg-id"
    local recipient secret_fingerprint probe_file
    local has_secret=false
    local -a recipients=()
    local -a encryption_args=()

    [[ ! -L "$gpg_id_file" && -f "$gpg_id_file" && -s "$gpg_id_file" ]] \
        || die "The pass recipient file is missing, empty, symbolic, or non-regular: ${gpg_id_file}"
    mapfile -t recipients < <(
        awk '{ line=$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); if (line != "" && line !~ /^#/) print line }' "$gpg_id_file"
    )
    [[ "${#recipients[@]}" -gt 0 ]] || die 'The pass recipient file contains no usable recipients.'

    for recipient in "${recipients[@]}"; do
        gpg --batch --list-keys -- "$recipient" >/dev/null 2>&1 \
            || die "A public GPG key required by pass is unavailable: ${recipient}"
        encryption_args+=(--recipient "$recipient")
        if secret_fingerprint="$(resolve_secret_key_fingerprint "$recipient")"; then
            [[ -n "$secret_fingerprint" ]] && has_secret=true
        fi
    done
    [[ "$has_secret" == true ]] \
        || die 'None of the pass recipients has a usable encryption-capable secret key for this account.'

    probe_file="$(mktemp)"
    TEMP_FILES+=("$probe_file")
    printf '%s\n' 'ls-server-init credential-store validation' \
        | gpg --batch --yes --output "$probe_file" --encrypt "${encryption_args[@]}" >/dev/null 2>&1 \
        || die 'GPG cannot encrypt for every recipient configured in the pass store.'
    pass ls >/dev/null 2>&1 || die 'The pass credential store is not usable.'
}

ensure_pass_store() {
    local gpg_id_file="${PASS_STORE_DIR}/.gpg-id"
    local default_fingerprint selector fingerprint generate_choice=''

    prepare_private_directory "$PASS_STORE_DIR" 'password-store directory'
    [[ ! -L "$gpg_id_file" ]] || die "Refusing symbolic-link pass recipient file: ${gpg_id_file}"
    [[ ! -e "$gpg_id_file" || -f "$gpg_id_file" ]] \
        || die "Pass recipient path is not a regular file: ${gpg_id_file}"

    if [[ -s "$gpg_id_file" ]]; then
        validate_pass_recipients
        print_info 'The pass credential store is initialized and usable.'
        return 0
    fi

    default_fingerprint="$(first_usable_secret_fingerprint || true)"
    if [[ -z "$default_fingerprint" ]]; then
        print_warning 'No usable encryption-capable GPG secret key was found for this account.'
        read -r -p 'Generate one now? [Y/n]: ' generate_choice
        generate_choice="${generate_choice:-Y}"
        [[ "$generate_choice" =~ ^[Yy]$ ]] || die 'A usable GPG secret key is required to initialize pass.'
        gpg --full-generate-key
        default_fingerprint="$(first_usable_secret_fingerprint || true)"
        [[ -n "$default_fingerprint" ]] || die 'Unable to find a usable newly generated GPG secret key.'
    fi

    read -r -p "GPG secret-key fingerprint for pass [${default_fingerprint}]: " selector
    selector="${selector:-$default_fingerprint}"
    fingerprint="$(resolve_secret_key_fingerprint "$selector" || true)"
    [[ -n "$fingerprint" ]] \
        || die 'The selection must resolve to exactly one usable encryption-capable secret key.'
    pass init "$fingerprint"
    validate_pass_recipients
    print_info 'Initialized and validated the pass credential store with a full key fingerprint.'
}

read_helper_list() {
    local helper_json

    helper_json="$(docker-credential-pass list)" || return 1
    jq -e 'type == "object"' <<< "$helper_json" >/dev/null 2>&1 \
        || return 1
    printf '%s\n' "$helper_json"
}

verify_effective_helper() {
    local config_file="$1"
    local target="$2"
    local effective_helper

    effective_helper="$(
        jq -r --arg target "$target" \
            '(.credHelpers[$target] // .credsStore // "")' "$config_file"
    )"
    [[ "$effective_helper" == 'pass' ]]
}

create_docker_config_snapshot() {
    local config_file="$1"
    local config_dir="$2"

    DOCKER_CONFIG_ORIGINAL_EXISTED=false
    DOCKER_CONFIG_SNAPSHOT=''
    if [[ -e "$config_file" ]]; then
        DOCKER_CONFIG_ORIGINAL_EXISTED=true
        DOCKER_CONFIG_SNAPSHOT="$(mktemp "${config_dir}/.config.json.rollback.XXXXXX")" \
            || die 'Unable to create a Docker configuration rollback snapshot.'
        TEMP_FILES+=("$DOCKER_CONFIG_SNAPSHOT")
        cp --preserve=all -- "$config_file" "$DOCKER_CONFIG_SNAPSHOT" \
            || die 'Unable to create a Docker configuration rollback snapshot.'
        chmod 0600 -- "$DOCKER_CONFIG_SNAPSHOT"
    fi
    DOCKER_CONFIG_TRANSACTION_READY=true
}

configure_docker_client() {
    local mode="$1"
    local target="$2"
    local timestamp="$3"
    local source_file temp_file existing_store existing_helper inline_auth_output confirmation=''
    local replace_override=false
    local -a inline_auth_keys=()

    prepare_private_directory "$DOCKER_CONFIG_DIR" 'Docker client configuration directory'
    [[ ! -L "$DOCKER_CONFIG_FILE" ]] \
        || die "Refusing symbolic-link Docker client configuration: ${DOCKER_CONFIG_FILE}"
    [[ ! -e "$DOCKER_CONFIG_FILE" || -f "$DOCKER_CONFIG_FILE" ]] \
        || die "Docker client configuration is not a regular file: ${DOCKER_CONFIG_FILE}"
    if [[ -e "$DOCKER_CONFIG_FILE" ]]; then
        jq -e '
            type == "object"
            and (
                if has("credsStore") then
                    (.credsStore | type == "string" and length > 0)
                else true end
            )
            and (
                if has("credHelpers") then
                    if (.credHelpers | type) == "object" then
                        all(.credHelpers[]; type == "string" and length > 0)
                    else false end
                else true end
            )
            and (
                if has("auths") then
                    if (.auths | type) == "object" then
                        all(.auths[]; type == "object")
                    else false end
                else true end
            )
        ' "$DOCKER_CONFIG_FILE" >/dev/null 2>&1 \
            || die "${DOCKER_CONFIG_FILE} has invalid credsStore, credHelpers, or auths fields."
        source_file="$DOCKER_CONFIG_FILE"
    else
        source_file="$(mktemp)"
        TEMP_FILES+=("$source_file")
        printf '%s\n' '{}' > "$source_file"
    fi

    if [[ "$mode" == 'credsStore' ]]; then
        inline_auth_output="$(
            jq -r '
                def contains_inline_credential:
                    [.auth?, .identitytoken?, .registrytoken?, .password?]
                    | any(.[]; type == "string" and length > 0);
                (.auths // {})
                | to_entries[]
                | select(.value | contains_inline_credential)
                | .key
            ' "$source_file"
        )" || die 'Unable to inspect existing inline Docker credentials.'
        if [[ -n "$inline_auth_output" ]]; then
            mapfile -t inline_auth_keys <<< "$inline_auth_output"
        fi
        if (( ${#inline_auth_keys[@]} > 0 )); then
            print_warning 'Making pass the default store means Docker will stop using these existing inline credential entries:'
            printf '  - %s\n' "${inline_auth_keys[@]}"
            print_warning 'The selected registry will be logged in again, but other registry credentials are not migrated.'
            read -r -p 'Type GLOBAL to continue with a default credential store: ' confirmation
            [[ "$confirmation" == 'GLOBAL' ]] || die 'Global credential-store configuration was not confirmed.'
        fi
    fi

    existing_store="$(jq -r '.credsStore // ""' "$source_file")"
    if [[ "$mode" == 'credsStore' && -n "$existing_store" && "$existing_store" != 'pass' ]]; then
        confirmation=''
        print_warning "Docker currently uses '${existing_store}' as its default credential store."
        read -r -p 'Type REPLACE to make pass the default credential store instead: ' confirmation
        [[ "$confirmation" == 'REPLACE' ]] || die 'Default credential-store replacement was not confirmed.'
    fi

    existing_helper="$(jq -r --arg target "$target" '.credHelpers[$target] // ""' "$source_file")"
    if [[ -n "$existing_helper" && "$existing_helper" != 'pass' ]]; then
        confirmation=''
        print_warning "${target} currently overrides the default credential store with helper '${existing_helper}'."
        if [[ "$mode" == 'credsStore' ]]; then
            read -r -p "Type REPLACE to remove only this registry-specific override: " confirmation
        else
            read -r -p "Type REPLACE to replace only this registry-specific helper with pass: " confirmation
        fi
        [[ "$confirmation" == 'REPLACE' ]] || die 'Credential-helper replacement was not confirmed.'
        replace_override=true
    fi

    temp_file="$(mktemp "${DOCKER_CONFIG_DIR}/.config.json.XXXXXX")"
    TEMP_FILES+=("$temp_file")
    if [[ "$mode" == 'credsStore' ]]; then
        jq --arg target "$target" --argjson replace_override "$replace_override" '
            def remove_selected_auth($registry):
                if $registry == "https://index.docker.io/v1/" then
                    del(
                        .auths[$registry],
                        .auths["https://index.docker.io/v1"],
                        .auths["docker.io"],
                        .auths["index.docker.io"]
                    )
                else
                    del(
                        .auths[$registry],
                        .auths["https://" + $registry],
                        .auths["https://" + $registry + "/"],
                        .auths["http://" + $registry],
                        .auths["http://" + $registry + "/"]
                    )
                end;
            .credsStore = "pass"
            | if $replace_override then del(.credHelpers[$target]) else . end
            | remove_selected_auth($target)
        ' "$source_file" > "$temp_file"
    else
        jq --arg target "$target" '
            def remove_selected_auth($registry):
                if $registry == "https://index.docker.io/v1/" then
                    del(
                        .auths[$registry],
                        .auths["https://index.docker.io/v1"],
                        .auths["docker.io"],
                        .auths["index.docker.io"]
                    )
                else
                    del(
                        .auths[$registry],
                        .auths["https://" + $registry],
                        .auths["https://" + $registry + "/"],
                        .auths["http://" + $registry],
                        .auths["http://" + $registry + "/"]
                    )
                end;
            .credHelpers = (.credHelpers // {})
            | .credHelpers[$target] = "pass"
            | remove_selected_auth($target)
        ' "$source_file" > "$temp_file"
    fi
    jq -e 'type == "object"' "$temp_file" >/dev/null 2>&1 \
        || die 'Generated Docker client configuration is invalid.'

    create_docker_config_snapshot "$DOCKER_CONFIG_FILE" "$DOCKER_CONFIG_DIR"
    if cmp -s <(jq -S -c . "$temp_file") <(jq -S -c . "$source_file"); then
        if [[ -f "$DOCKER_CONFIG_FILE" ]]; then
            chmod 0600 -- "$DOCKER_CONFIG_FILE"
        fi
        print_info 'Docker client credential configuration is already semantically current.'
    else
        if [[ -e "$DOCKER_CONFIG_FILE" ]]; then
            DOCKER_CONFIG_BACKUP="${DOCKER_CONFIG_FILE}.ls-server-init.${timestamp}.bak"
            backup_user_file "$DOCKER_CONFIG_FILE" "$timestamp"
        fi
        chmod 0600 -- "$temp_file"
        mv -fT -- "$temp_file" "$DOCKER_CONFIG_FILE"
        print_info "Updated ${DOCKER_CONFIG_FILE} without removing unrelated settings."
    fi
    verify_effective_helper "$DOCKER_CONFIG_FILE" "$target" \
        || die "Docker configuration does not effectively select pass for ${target}."
}

rollback_docker_client() {
    local restore_temp

    [[ "$DOCKER_CONFIG_TRANSACTION_READY" == true ]] || return 0
    if [[ "$DOCKER_CONFIG_ORIGINAL_EXISTED" == true ]]; then
        [[ -n "$DOCKER_CONFIG_SNAPSHOT" && ! -L "$DOCKER_CONFIG_SNAPSHOT" && -f "$DOCKER_CONFIG_SNAPSHOT" ]] \
            || return 1
        jq -e 'type == "object"' "$DOCKER_CONFIG_SNAPSHOT" >/dev/null 2>&1 || return 1
        restore_temp="$(mktemp "${DOCKER_CONFIG_DIR}/.config.json.restore.XXXXXX")" || return 1
        TEMP_FILES+=("$restore_temp")
        if ! cp --preserve=all -- "$DOCKER_CONFIG_SNAPSHOT" "$restore_temp"; then
            rm -f -- "$restore_temp" || true
            return 1
        fi
        if ! mv -fT -- "$restore_temp" "$DOCKER_CONFIG_FILE"; then
            rm -f -- "$restore_temp" || true
            return 1
        fi
        cmp -s "$DOCKER_CONFIG_SNAPSHOT" "$DOCKER_CONFIG_FILE" || return 1
    else
        rm -f -- "$DOCKER_CONFIG_FILE" || return 1
        [[ ! -e "$DOCKER_CONFIG_FILE" && ! -L "$DOCKER_CONFIG_FILE" ]] || return 1
    fi
    DOCKER_CONFIG_TRANSACTION_READY=false
    return 0
}

fail_with_config_rollback() {
    local reason="$1"

    print_error "$reason"
    if rollback_docker_client; then
        print_warning 'Only config.json was rolled back. Docker may already have created or replaced the selected encrypted pass entry; a later successful login will replace it.'
        die 'The previous Docker client configuration was restored.'
    fi
    PRESERVE_CONFIG_SNAPSHOT=true
    DOCKER_CONFIG_TRANSACTION_READY=false
    if [[ -n "$DOCKER_CONFIG_SNAPSHOT" ]]; then
        die "The previous Docker client configuration could not be restored; recover it from ${DOCKER_CONFIG_SNAPSHOT}."
    fi
    die "The previous Docker client configuration could not be restored; inspect or remove ${DOCKER_CONFIG_FILE} manually."
}

[[ -t 0 ]] || die 'This login helper requires an interactive terminal.'
if [[ "$EUID" -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != 'root' ]]; then
        die "Do not run this helper with sudo. Run it directly as ${SUDO_USER} so Docker and pass use that account's home directory."
    fi
    read -r -p 'This will create Docker credentials for root. Type ROOT to continue: ' root_confirmation
    [[ "$root_confirmation" == 'ROOT' ]] || die 'Root credential-store configuration was not confirmed.'
else
    require_command sudo
    SUDO=(sudo)
fi

for required in docker apt-get dpkg getent id cut stat install chmod rm; do require_command "$required"; done

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
account_home="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
[[ -n "$account_home" && -d "$account_home" && ! -L "$account_home" ]] \
    || die "Cannot determine a safe home directory for ${CURRENT_USER}."
[[ "$(stat -c '%u' -- "$account_home")" == "$CURRENT_UID" ]] \
    || die "The home directory for ${CURRENT_USER} is not owned by that account."
export HOME="$account_home"

custom_gnupg_home=false
custom_password_store=false
custom_docker_config=false
[[ -n "${GNUPGHOME:-}" ]] && custom_gnupg_home=true
[[ -n "${PASSWORD_STORE_DIR:-}" ]] && custom_password_store=true
[[ -n "${DOCKER_CONFIG:-}" ]] && custom_docker_config=true

GPG_HOME="$(normalize_absolute_directory 'GNUPGHOME' "${GNUPGHOME:-${HOME}/.gnupg}")"
PASS_STORE_DIR="$(normalize_absolute_directory 'PASSWORD_STORE_DIR' "${PASSWORD_STORE_DIR:-${HOME}/.password-store}")"
DOCKER_CONFIG_DIR="$(normalize_absolute_directory 'DOCKER_CONFIG' "${DOCKER_CONFIG:-${HOME}/.docker}")"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG_DIR}/config.json"
assert_safe_directory_path "$GPG_HOME" 'GnuPG home directory'
assert_safe_directory_path "$PASS_STORE_DIR" 'password-store directory'
assert_safe_directory_path "$DOCKER_CONFIG_DIR" 'Docker client configuration directory'
export GNUPGHOME="$GPG_HOME"
export PASSWORD_STORE_DIR="$PASS_STORE_DIR"
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

if [[ "$custom_gnupg_home" == true || "$custom_password_store" == true || "$custom_docker_config" == true ]]; then
    print_warning 'Custom GNUPGHOME, PASSWORD_STORE_DIR, or DOCKER_CONFIG values must be exported in every future shell that runs Docker.'
fi

REGISTRY=''
REGISTRY_LABEL=''
CONFIG_MODE='credHelpers'
while true; do
    print_info 'Select a registry:'
    printf '%s\n' '1) Docker Hub' '2) Custom registry'
    read -r -p 'Choose [1-2]: ' registry_choice
    case "$registry_choice" in
        1)
            REGISTRY=''
            REGISTRY_LABEL='Docker Hub'
            TARGET_CONFIG_KEY="$DOCKER_HUB_CONFIG_KEY"
            break
            ;;
        2)
            read -r -p 'Registry hostname (example: registry.example.com:5000): ' REGISTRY
            valid_registry "$REGISTRY" || {
                print_error 'Enter a hostname or bracketed IPv6 address, optionally followed by a valid port; do not include a URL scheme or path.'
                continue
            }
            REGISTRY="${REGISTRY,,}"
            REGISTRY_LABEL="$REGISTRY"
            TARGET_CONFIG_KEY="$(canonical_registry_key "$REGISTRY")"
            break
            ;;
        *) print_error 'Choose 1 or 2.' ;;
    esac
done

while true; do
    printf '%s\n' \
        "1) Use pass only for ${REGISTRY_LABEL} (recommended)" \
        '2) Use pass as the default store for all registries without a specific helper'
    read -r -p 'Choose [1-2, default 1]: ' config_choice
    config_choice="${config_choice:-1}"
    case "$config_choice" in
        1) CONFIG_MODE='credHelpers'; break ;;
        2)
            print_warning 'Default-store mode affects every registry without its own credHelpers entry.'
            CONFIG_MODE='credsStore'
            break
            ;;
        *) print_error 'Choose 1 or 2.' ;;
    esac
done

print_info 'Installing credential-store prerequisites...'
"${SUDO[@]}" apt-get update
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg2 jq pass pinentry-tty
for required in awk cmp cp curl date gpg gpgconf install jq mktemp mv pass sha256sum stat tty; do require_command "$required"; done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
install_credential_helper "$timestamp"
configure_pinentry "$timestamp"
ensure_pass_store
read_helper_list >/dev/null \
    || die 'docker-credential-pass cannot read a valid listing from the initialized pass store.'
configure_docker_client "$CONFIG_MODE" "$TARGET_CONFIG_KEY" "$timestamp"

print_info 'Starting an interactive docker login. Passwords and tokens are handled by Docker and pass, not printed by this script.'
if [[ -z "$REGISTRY" ]]; then
    docker login || fail_with_config_rollback 'Docker login failed.'
else
    docker login "$REGISTRY" || fail_with_config_rollback 'Docker login failed.'
fi

verify_effective_helper "$DOCKER_CONFIG_FILE" "$TARGET_CONFIG_KEY" \
    || fail_with_config_rollback 'Docker no longer selects pass for the chosen registry.'
helper_listing="$(read_helper_list)" \
    || fail_with_config_rollback 'docker-credential-pass could not list credentials after login.'
jq -e --arg target "$TARGET_CONFIG_KEY" \
    'type == "object" and length > 0 and has($target)' <<< "$helper_listing" >/dev/null 2>&1 \
    || fail_with_config_rollback 'The chosen registry was not found in docker-credential-pass after login.'

remaining_inline_auth_output="$(
    jq -r '
        def contains_inline_credential:
            [.auth?, .identitytoken?, .registrytoken?, .password?]
            | any(.[]; type == "string" and length > 0);
        (.auths // {})
        | to_entries[]
        | select(.value | type == "object")
        | select(.value | contains_inline_credential)
        | .key
    ' "$DOCKER_CONFIG_FILE"
)" || fail_with_config_rollback 'Docker client configuration could not be inspected after login.'
remaining_inline_auths=()
if [[ -n "$remaining_inline_auth_output" ]]; then
    mapfile -t remaining_inline_auths <<< "$remaining_inline_auth_output"
fi

DOCKER_CONFIG_TRANSACTION_READY=false
print_info 'Docker login completed and the selected registry is stored with docker-credential-pass.'
if (( ${#remaining_inline_auths[@]} > 0 )); then
    print_warning 'Inline Docker credentials remain in config.json for these registry keys:'
    printf '  - %s\n' "${remaining_inline_auths[@]}"
    if [[ "$CONFIG_MODE" == 'credsStore' ]]; then
        print_warning 'They were not migrated and the default pass store now masks them. Re-login each registry through pass before relying on it.'
    else
        print_warning 'They were not migrated. Run this helper for each registry if you want to move them out of config.json.'
    fi
fi
if [[ -n "$DOCKER_CONFIG_BACKUP" ]]; then
    print_warning "The mode-0600 backup ${DOCKER_CONFIG_BACKUP} contains the previous Docker client configuration."
    print_warning 'Remove that backup after you verify the new login if you no longer need rollback data.'
fi
