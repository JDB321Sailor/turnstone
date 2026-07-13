#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ROOT_ENV="$REPO_DIR/.env"
TRAEFIK_ENV="$SCRIPT_DIR/config/traefik.env"
TRAEFIK_CONFIG="$SCRIPT_DIR/config/traefik.yaml"
OIDC_ENV="$SCRIPT_DIR/config/turnstone-oidc.env"
DYNAMIC_AUTH="$SCRIPT_DIR/dynamic/dashboard-auth.yaml"
ACME_FILE="$SCRIPT_DIR/acme/acme.json"
TEMPLATE_ENV="$SCRIPT_DIR/example.env"
TEMPLATE_CONFIG="$SCRIPT_DIR/example.config.yaml"
TEMPLATE_OIDC_ENV="$SCRIPT_DIR/example.oidc.env"
TEMPLATE_OVERRIDE="$SCRIPT_DIR/override.compose.yaml"
ROOT_OVERRIDE="$REPO_DIR/override.compose.yaml"
NODE_OVERRIDE="$REPO_DIR/compose.override.yaml"
ROOT_OVERRIDE_MARKER="# Managed by traefik/setup-traefik.sh"
NODE_OVERRIDE_MARKER="# turnstone run.sh — node-count limiter (safe to delete)"
DOCKER="docker"
OS_ID=""
OS_LIKE=""
PKG=""
IS_WSL=0
SUDO=""
OS_PLATFORM_ID=""
OS_CODENAME=""
OS_UBUNTU_CODENAME=""
NODE_COUNT=10
ROOTLESS=0
CADDY_PORT=8443
PG_PORT=5432

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
info() { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

on_error() {
    local rc=$?
    printf '\n%serror:%s setup-traefik.sh stopped unexpectedly (exit %s). Review the output above and re-run.\n' \
        "$RED" "$RESET" "$rc" >&2
}
trap on_error ERR

# Prompt helpers
ask() {
    local prompt="$1" default="${2:-y}" ans hint
    [ "$default" = y ] && hint="Y/n" || hint="y/N"
    if [ -n "${TURNSTONE_SETUP_ASSUME_YES:-}" ]; then
        [ "$default" = y ]
        return
    fi
    if [ ! -r /dev/tty ]; then
        warn "non-interactive shell; assuming '$default' for: $prompt"
        [ "$default" = y ]
        return
    fi
    printf '%s%s%s [%s] ' "$BOLD" "$prompt" "$RESET" "$hint" >/dev/tty
    read -r ans </dev/tty || ans=""
    ans="${ans:-$default}"
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

prompt_value() {
    local outvar="$1" envvar="$2" prompt="$3" default="${4:-}" secret="${5:-0}" value=""
    if [[ -v $envvar ]]; then
        printf -v "$outvar" '%s' "${!envvar}"
        return
    fi
    if [ "$secret" = 1 ] && [ -n "$default" ]; then
        if ask "Keep the existing value for ${prompt}?" y; then
            printf -v "$outvar" '%s' "$default"
            return
        fi
    fi
    if [ ! -r /dev/tty ]; then
        if [ -n "$default" ]; then
            warn "non-interactive shell; keeping existing/default value for: $prompt"
            printf -v "$outvar" '%s' "$default"
            return
        fi
        die "missing required input for: $prompt. Set ${envvar}."
    fi
    if [ "$secret" = 1 ]; then
        while :; do
            printf '%s%s%s: ' "$BOLD" "$prompt" "$RESET" >/dev/tty
            read -r -s value </dev/tty || value=""
            printf '\n' >/dev/tty
            if [ -n "$value" ]; then
                printf -v "$outvar" '%s' "$value"
                return
            fi
            printf 'A value is required.\n' >/dev/tty
        done
    fi
    while :; do
        if [ -n "$default" ]; then
            printf '%s%s%s [%s]: ' "$BOLD" "$prompt" "$RESET" "$default" >/dev/tty
        else
            printf '%s%s%s: ' "$BOLD" "$prompt" "$RESET" >/dev/tty
        fi
        read -r value </dev/tty || value=""
        value="${value:-$default}"
        if [ -n "$value" ]; then
            printf -v "$outvar" '%s' "$value"
            return
        fi
        printf 'A value is required.\n' >/dev/tty
    done
}

prompt_toggle() {
    local outvar="$1" envvar="$2" prompt="$3" default="${4:-n}" value
    if [[ -v $envvar ]]; then
        case "${!envvar}" in
            [Yy]|[Yy][Ee][Ss]|1|true|TRUE) printf -v "$outvar" 'true' ;;
            *) printf -v "$outvar" 'false' ;;
        esac
        return
    fi
    if ask "$prompt" "$default"; then
        value=true
    else
        value=false
    fi
    printf -v "$outvar" '%s' "$value"
}

# Platform helpers

detect_os() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_LIKE="${ID_LIKE:-}"
        OS_PLATFORM_ID="${PLATFORM_ID:-}"
        OS_CODENAME="${VERSION_CODENAME:-}"
        OS_UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
    fi
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
        IS_WSL=1
    fi
    case " $OS_ID $OS_LIKE " in
        *" arch "*|*manjaro*) PKG=pacman ;;
        *" ubuntu "*|*" debian "*) PKG=apt ;;
        *" fedora "*|*" rhel "*|*" centos "*) PKG=dnf ;;
        *)
            if have apt-get; then PKG=apt
            elif have dnf; then PKG=dnf
            elif have yum; then PKG=yum
            elif have pacman; then PKG=pacman
            fi
            ;;
    esac
    [ -n "$PKG" ] || die "could not detect a supported package manager (apt/dnf/yum/pacman)."
    [ "$PKG" = dnf ] && ! have dnf && have yum && PKG=yum
    if [ "$(id -u)" -ne 0 ]; then
        have sudo || die "this script needs root for package installs — install sudo or run as root."
        SUDO="sudo"
    fi
}

pkg_install() {
    info "Installing: $*"
    case "$PKG" in
        apt) $SUDO apt-get update -y && $SUDO apt-get install -y "$@" ;;
        dnf) $SUDO dnf install -y "$@" ;;
        yum) $SUDO yum install -y "$@" ;;
        pacman) $SUDO pacman -Sy --needed --noconfirm "$@" ;;
    esac
}

ensure_git() {
    have git && return
    warn "git is not installed."
    ask "Install git now?" y || die "git is required."
    pkg_install git || die "git installation failed."
}

install_docker_ce_repo() {
    local up codename arch
    case "$PKG" in
        apt)
            if [ -n "$OS_UBUNTU_CODENAME" ]; then
                up=ubuntu
                codename="$OS_UBUNTU_CODENAME"
            else
                up=debian
                codename="$OS_CODENAME"
            fi
            [ -n "$codename" ] || die "could not determine the release codename for Docker's repository."
            arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
            $SUDO install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$up/gpg" | $SUDO tee /etc/apt/keyrings/docker.asc >/dev/null
            $SUDO chmod a+r /etc/apt/keyrings/docker.asc
            printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
                "$arch" "$up" "$codename" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
            $SUDO apt-get update -y
            $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf|yum)
            case "$OS_PLATFORM_ID" in
                platform:f*) up=fedora ;;
                platform:el*) up=centos ;;
                *) if [ -e /etc/fedora-release ]; then up=fedora; else up=centos; fi ;;
            esac
            $SUDO curl -fsSL "https://download.docker.com/linux/$up/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        pacman)
            pkg_install docker docker-compose
            ;;
    esac
}

get_docker_com_supports() {
    case "$1" in
        ubuntu|debian|raspbian|centos|fedora|rhel|rocky|sles|fedora-asahi-remix) return 0 ;;
        *) return 1 ;;
    esac
}

install_docker() {
    case "$PKG" in
        apt|dnf|yum)
            if [ -n "$OS_ID" ] && get_docker_com_supports "$OS_ID"; then
                curl -fsSL https://get.docker.com | $SUDO sh
            else
                install_docker_ce_repo
            fi
            ;;
        pacman)
            install_docker_ce_repo
            ;;
    esac
    if have systemctl; then
        $SUDO systemctl enable --now docker 2>/dev/null || true
    fi
    if [ "$(id -u)" -ne 0 ] && getent group docker >/dev/null 2>&1; then
        $SUDO usermod -aG docker "$USER" 2>/dev/null || true
    fi
}

start_docker_daemon() {
    if have systemctl; then
        $SUDO systemctl start docker 2>/dev/null || true
    elif have service; then
        $SUDO service docker start 2>/dev/null || true
    fi
}

ensure_docker_usable() {
    if ! have docker; then
        warn "Docker is not installed."
        ask "Install Docker now?" y || die "Docker is required."
        install_docker
    fi
    docker info >/dev/null 2>&1 && { DOCKER="docker"; return; }
    start_docker_daemon
    docker info >/dev/null 2>&1 && { DOCKER="docker"; return; }
    if [ "$(id -u)" -ne 0 ] && have sudo && sudo docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
        warn "Using 'sudo docker' for this run."
        return
    fi
    if [ "$IS_WSL" -eq 1 ]; then
        die "Docker is not usable inside WSL without Docker Desktop integration."
    fi
    die "Docker is installed but not usable. Start the daemon or fix permissions, then re-run."
}

ensure_compose() {
    $DOCKER compose version >/dev/null 2>&1 && return
    warn "The Docker Compose v2 plugin is missing."
    case "$PKG" in
        apt|dnf|yum)
            if ask "Install docker-compose-plugin?" y; then
                pkg_install docker-compose-plugin
            fi
            ;;
        pacman)
            if ask "Install docker-compose?" y; then
                pkg_install docker-compose
            fi
            ;;
    esac
    $DOCKER compose version >/dev/null 2>&1 || die "'docker compose' is unavailable."
}

# Environment helpers

env_get() {
    local file="$1" key="$2" default="$3" value
    if [ ! -f "$file" ]; then
        printf '%s' "$default"
        return
    fi
    value="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ -z "$value" ]; then
        printf '%s' "$default"
        return
    fi
    case "$value" in
        \"*\")
            value=${value#\"}
            value=${value%\"}
            value=${value//\\\"/\"}
            value=${value//\\\\/\\}
            ;;
    esac
    printf '%s' "$value"
}

env_format() {
    local value="$1"
    if [ -z "$value" ] || [[ "$value" =~ [[:space:]#\"] ]]; then
        value=${value//\\/\\\\}
        value=${value//\"/\\\"}
        printf '"%s"' "$value"
    else
        printf '%s' "$value"
    fi
}

set_env_key() {
    local file="$1" key="$2" value="$3" tmp
    tmp="$(mktemp)"
    if [ -f "$file" ]; then
        awk -v key="$key" 'index($0, key "=") != 1 { print }' "$file" >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

is_managed_file() {
    local file="$1"
    [ -f "$file" ] && head -1 "$file" 2>/dev/null | grep -qF "$ROOT_OVERRIDE_MARKER"
}

write_managed_file() {
    local file="$1" template="${2:-}" tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    if [ -f "$file" ] && ! is_managed_file "$file"; then
        if [ -n "$template" ] && cmp -s "$file" "$template"; then
            :
        else
        ask "Overwrite existing unmanaged file $file?" n || die "Refusing to overwrite $file."
        fi
    fi
    mkdir -p "$(dirname "$file")"
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

copy_template_if_missing() {
    local src="$1" dest="$2" mode="${3:-0644}"
    if [ -f "$dest" ]; then
        return
    fi
    install -m "$mode" "$src" "$dest"
}

port_in_use() {
    local port="$1"
    if have ss; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0 || return 1
    fi
    if have lsof; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0 || return 1
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}

port_free() { ! port_in_use "$1"; }

random_high_port() {
    local port
    for (( attempt = 0; attempt < 25; attempt++ )); do
        port=$(( (RANDOM % 64000) + 1024 ))
        port_free "$port" && { echo "$port"; return; }
    done
}

pick_caddy_port() {
    if [ "$ROOTLESS" -eq 0 ] && port_free 443; then echo 443; return; fi
    port_free 8443 && { echo 8443; return; }
    random_high_port || true
}

pick_pg_port() {
    port_free 5432 && { echo 5432; return; }
    random_high_port || true
}

gen_hex() {
    if have openssl; then openssl rand -hex "$1"
    elif have python3; then python3 -c 'import secrets,sys; print(secrets.token_hex(int(sys.argv[1])))' "$1"
    else head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

gen_password() {
    local value
    value="$(gen_hex "$1")"
    printf '%s' "$value"
}

hash_basic_auth() {
    local user="$1" secret="$2" line
    line="$($DOCKER run --rm --entrypoint htpasswd httpd:2.4-alpine -nbB "$user" "$secret")"
    printf '%s' "$line"
}

prepare_root_env() {
    local jwt pgpw existing_jwt existing_pgpw existing_host existing_postgres_port existing_caddy_port existing_compose target_compose
    if [ -f "$ROOT_ENV" ]; then
        chmod 600 "$ROOT_ENV" 2>/dev/null || true
        info "Keeping existing $ROOT_ENV and updating Traefik-related keys."
    fi
    existing_jwt="$(env_get "$ROOT_ENV" TURNSTONE_JWT_SECRET "")"
    existing_pgpw="$(env_get "$ROOT_ENV" POSTGRES_PASSWORD "")"
    existing_host="$(env_get "$ROOT_ENV" TURNSTONE_HOST_IP "127.0.0.1")"
    existing_postgres_port="$(env_get "$ROOT_ENV" POSTGRES_PORT "")"
    existing_caddy_port="$(env_get "$ROOT_ENV" CONSOLE_HTTPS_PORT "")"
    existing_compose="$(env_get "$ROOT_ENV" COMPOSE_FILE "")"
    target_compose="compose.yaml:override.compose.yaml:compose.override.yaml"
    [ -n "$existing_jwt" ] && jwt="$existing_jwt" || jwt="$(gen_hex 32)"
    [ -n "$existing_pgpw" ] && pgpw="$existing_pgpw" || pgpw="$(gen_hex 18)"
    if [ -n "$existing_postgres_port" ]; then PG_PORT="$existing_postgres_port"; else PG_PORT="$(pick_pg_port)"; fi
    if [ -n "$existing_caddy_port" ]; then CADDY_PORT="$existing_caddy_port"; else CADDY_PORT="$(pick_caddy_port)"; fi
    [ -n "$CADDY_PORT" ] || CADDY_PORT=8443
    [ -n "$PG_PORT" ] || PG_PORT=5432
    (
        umask 077
        touch "$ROOT_ENV"
    )
    set_env_key "$ROOT_ENV" TURNSTONE_JWT_SECRET "$jwt"
    set_env_key "$ROOT_ENV" POSTGRES_USER "turnstone"
    set_env_key "$ROOT_ENV" POSTGRES_PASSWORD "$pgpw"
    set_env_key "$ROOT_ENV" TURNSTONE_HOST_IP "$existing_host"
    set_env_key "$ROOT_ENV" POSTGRES_PORT "$PG_PORT"
    set_env_key "$ROOT_ENV" CONSOLE_HTTPS_PORT "$CADDY_PORT"
    if [ -n "$existing_compose" ] && [ "$existing_compose" != "$target_compose" ]; then
        ask "Replace existing COMPOSE_FILE in $ROOT_ENV so plain docker compose commands include Traefik?" y || die "Cannot proceed without updating COMPOSE_FILE. Re-run the script after allowing the Traefik override."
    fi
    set_env_key "$ROOT_ENV" COMPOSE_FILE "$target_compose"
    chmod 600 "$ROOT_ENV"
}

pick_node_count() {
    local default answer
    default="${TURNSTONE_SETUP_NODE_COUNT:-$(env_get "$ROOT_ENV" TURNSTONE_NODE_COUNT_HINT "10")}"
    if [ ! -r /dev/tty ] && [ -z "${TURNSTONE_SETUP_NODE_COUNT:-}" ]; then
        info "Non-interactive shell — starting the recommended 10-node cluster."
        NODE_COUNT=10
        return
    fi
    while :; do
        prompt_value answer TURNSTONE_SETUP_NODE_COUNT "How many server nodes should run (1-10)" "$default"
        case "$answer" in
            [1-9]|10) NODE_COUNT="$answer"; return ;;
            *) warn "Please enter a whole number from 1 to 10."; default=10 ;;
        esac
    done
}

write_node_override() {
    local file="$NODE_OVERRIDE" node
    if [ -f "$file" ] && ! head -1 "$file" 2>/dev/null | grep -qF "$NODE_OVERRIDE_MARKER"; then
        warn "$file exists and is not managed by run.sh. Leaving it unchanged."
        return
    fi
    if [ "$NODE_COUNT" -ge 10 ]; then
        cat >"$file" <<EOF_NODE
$NODE_OVERRIDE_MARKER
services: {}
EOF_NODE
    else
        {
            echo "$NODE_OVERRIDE_MARKER"
            echo "services:"
            for (( node = NODE_COUNT + 1; node <= 10; node++ )); do
                printf '  node-%s: { profiles: ["extra"] }\n' "$node"
            done
        } >"$file"
    fi
    chmod 600 "$file" 2>/dev/null || true
    set_env_key "$ROOT_ENV" TURNSTONE_NODE_COUNT_HINT "$NODE_COUNT"
}

# Traefik setup

copy_templates() {
    [ -f "$TEMPLATE_ENV" ] || die "missing $TEMPLATE_ENV"
    [ -f "$TEMPLATE_CONFIG" ] || die "missing $TEMPLATE_CONFIG"
    [ -f "$TEMPLATE_OIDC_ENV" ] || die "missing $TEMPLATE_OIDC_ENV"
    mkdir -p "$SCRIPT_DIR/config" "$SCRIPT_DIR/acme" "$SCRIPT_DIR/dynamic"
    copy_template_if_missing "$TEMPLATE_ENV" "$TRAEFIK_ENV" 0600
    copy_template_if_missing "$TEMPLATE_CONFIG" "$TRAEFIK_CONFIG" 0600
    copy_template_if_missing "$TEMPLATE_OIDC_ENV" "$OIDC_ENV" 0600
    if [ ! -f "$ACME_FILE" ]; then
        (
            umask 077
            printf '{}' >"$ACME_FILE"
        )
    fi
    chmod 600 "$TRAEFIK_ENV" "$TRAEFIK_CONFIG" "$OIDC_ENV" "$ACME_FILE"
}

collect_inputs() {
    local existing_cf existing_email existing_provider existing_user existing_password existing_app_host existing_dashboard_host oidc_enabled oidc_provider admin_group guidance_default trusted_default scopes_default provider_name_default role_claim_default role_map_default password_enabled_default redirect_default allow_private_default

    existing_app_host="$(env_get "$ROOT_ENV" TURNSTONE_TRAEFIK_APP_HOST "turnstone.example.com")"
    existing_dashboard_host="$(env_get "$ROOT_ENV" TURNSTONE_TRAEFIK_DASHBOARD_HOST "traefik.example.com")"
    existing_cf="$(env_get "$TRAEFIK_ENV" CF_DNS_API_TOKEN "")"
    existing_email="$(env_get "$TRAEFIK_ENV" TURNSTONE_TRAEFIK_ACME_EMAIL "admin@example.com")"
    existing_provider="$(env_get "$TRAEFIK_ENV" TURNSTONE_TRAEFIK_DNS_PROVIDER "cloudflare")"
    existing_user="$(env_get "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_USER "admin")"
    existing_password="$(env_get "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_PASSWORD "")"

    prompt_value TURNSTONE_TRAEFIK_APP_HOST TURNSTONE_SETUP_APP_HOST "Public hostname for the Turnstone UI" "$existing_app_host"
    prompt_value TURNSTONE_TRAEFIK_DASHBOARD_HOST TURNSTONE_SETUP_DASHBOARD_HOST "Public hostname for the Traefik dashboard" "$existing_dashboard_host"
    prompt_value TURNSTONE_TRAEFIK_ACME_EMAIL TURNSTONE_SETUP_ACME_EMAIL "ACME registration email" "$existing_email"
    prompt_value TURNSTONE_TRAEFIK_DNS_PROVIDER TURNSTONE_SETUP_DNS_PROVIDER "DNS challenge provider" "$existing_provider"
    [ "$TURNSTONE_TRAEFIK_DNS_PROVIDER" = "cloudflare" ] || die "only cloudflare is supported by this setup today."
    prompt_value CF_DNS_API_TOKEN TURNSTONE_SETUP_CF_DNS_API_TOKEN "Cloudflare DNS API token" "$existing_cf" 1
    prompt_value TRAEFIK_DASHBOARD_USER TURNSTONE_SETUP_DASHBOARD_USER "Dashboard basic-auth username" "$existing_user"
    if [ -n "${TURNSTONE_SETUP_DASHBOARD_PASSWORD:-}" ]; then
        TRAEFIK_DASHBOARD_PASSWORD="$TURNSTONE_SETUP_DASHBOARD_PASSWORD"
    elif [ -n "$existing_password" ] && [ "$existing_password" != "changeme" ]; then
        TRAEFIK_DASHBOARD_PASSWORD="$existing_password"
    else
        TRAEFIK_DASHBOARD_PASSWORD="$(gen_password 12)"
    fi

    prompt_toggle oidc_enabled TURNSTONE_SETUP_ENABLE_SSO "Configure OIDC single sign-on now?" n
    if [ "$oidc_enabled" = true ]; then
        prompt_value oidc_provider TURNSTONE_SETUP_OIDC_PROVIDER "OIDC provider (authentik or generic)" "${TURNSTONE_SETUP_OIDC_PROVIDER:-authentik}"
        case "$oidc_provider" in
            authentik|Authentik)
                info "Authentik guidance: the issuer URL normally looks like https://authentik.example.com/application/o/<app-slug>/ and the role claim is often groups."
                guidance_default="authentik Admins"
                provider_name_default="Authentik"
                role_claim_default="groups"
                ;;
            generic|Generic)
                oidc_provider=generic
                info "Generic guidance: use the values from docs/oidc.md for the selected provider."
                guidance_default="turnstone-admins"
                provider_name_default="SSO"
                role_claim_default="groups"
                ;;
            *) die "OIDC provider must be 'authentik' or 'generic'." ;;
        esac
        prompt_value admin_group TURNSTONE_SETUP_OIDC_ADMIN_GROUP "OIDC admin group or role value" "$guidance_default"
        scopes_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_SCOPES "openid email profile")"
        trusted_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS "")"
        password_enabled_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_PASSWORD_ENABLED "true")"
        redirect_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_REDIRECT_BASE "https://${TURNSTONE_TRAEFIK_APP_HOST}")"
        allow_private_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK "false")"
        provider_name_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_PROVIDER_NAME "$provider_name_default")"
        role_claim_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_ROLE_CLAIM "$role_claim_default")"
        role_map_default="$(env_get "$OIDC_ENV" TURNSTONE_OIDC_ROLE_MAP "${admin_group}:builtin-admin")"
        prompt_value TURNSTONE_OIDC_ISSUER TURNSTONE_SETUP_OIDC_ISSUER "TURNSTONE_OIDC_ISSUER" "$(env_get "$OIDC_ENV" TURNSTONE_OIDC_ISSUER "https://authentik.example.com/application/o/turnstone/")"
        prompt_value TURNSTONE_OIDC_CLIENT_ID TURNSTONE_SETUP_OIDC_CLIENT_ID "TURNSTONE_OIDC_CLIENT_ID" "$(env_get "$OIDC_ENV" TURNSTONE_OIDC_CLIENT_ID "turnstone")"
        prompt_value TURNSTONE_OIDC_CLIENT_SECRET TURNSTONE_SETUP_OIDC_CLIENT_SECRET "TURNSTONE_OIDC_CLIENT_SECRET" "$(env_get "$OIDC_ENV" TURNSTONE_OIDC_CLIENT_SECRET "")" 1
        prompt_value TURNSTONE_OIDC_SCOPES TURNSTONE_SETUP_OIDC_SCOPES "TURNSTONE_OIDC_SCOPES" "$scopes_default"
        prompt_value TURNSTONE_OIDC_PROVIDER_NAME TURNSTONE_SETUP_OIDC_PROVIDER_NAME "TURNSTONE_OIDC_PROVIDER_NAME" "$provider_name_default"
        prompt_value TURNSTONE_OIDC_ROLE_CLAIM TURNSTONE_SETUP_OIDC_ROLE_CLAIM "TURNSTONE_OIDC_ROLE_CLAIM" "$role_claim_default"
        prompt_value TURNSTONE_OIDC_ROLE_MAP TURNSTONE_SETUP_OIDC_ROLE_MAP "TURNSTONE_OIDC_ROLE_MAP" "$role_map_default"
        prompt_value TURNSTONE_OIDC_PASSWORD_ENABLED TURNSTONE_SETUP_OIDC_PASSWORD_ENABLED "TURNSTONE_OIDC_PASSWORD_ENABLED" "$password_enabled_default"
        prompt_value TURNSTONE_OIDC_REDIRECT_BASE TURNSTONE_SETUP_OIDC_REDIRECT_BASE "TURNSTONE_OIDC_REDIRECT_BASE" "$redirect_default"
        prompt_value TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS TURNSTONE_SETUP_OIDC_TRUSTED_ENDPOINT_HOSTS "TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS" "$trusted_default"
        prompt_value TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK TURNSTONE_SETUP_OIDC_ALLOW_PRIVATE_NETWORK "TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK" "$allow_private_default"
        TURNSTONE_SETUP_OIDC_PROVIDER="$oidc_provider"
    else
        TURNSTONE_SETUP_OIDC_PROVIDER=""
        TURNSTONE_OIDC_ISSUER=""
        TURNSTONE_OIDC_CLIENT_ID=""
        TURNSTONE_OIDC_CLIENT_SECRET=""
        TURNSTONE_OIDC_SCOPES="openid email profile"
        TURNSTONE_OIDC_PROVIDER_NAME="SSO"
        TURNSTONE_OIDC_ROLE_CLAIM=""
        TURNSTONE_OIDC_ROLE_MAP=""
        TURNSTONE_OIDC_PASSWORD_ENABLED="true"
        TURNSTONE_OIDC_REDIRECT_BASE=""
        TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS=""
        TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK="false"
    fi
}

write_traefik_env() {
    local dashboard_password_line
    dashboard_password_line="$(env_format "$TRAEFIK_DASHBOARD_PASSWORD")"
    write_managed_file "$TRAEFIK_ENV" "$TEMPLATE_ENV" <<EOF_TENV
$ROOT_OVERRIDE_MARKER
CF_DNS_API_TOKEN=$(env_format "$CF_DNS_API_TOKEN")
TURNSTONE_TRAEFIK_ACME_EMAIL=$(env_format "$TURNSTONE_TRAEFIK_ACME_EMAIL")
TURNSTONE_TRAEFIK_DNS_PROVIDER=$(env_format "$TURNSTONE_TRAEFIK_DNS_PROVIDER")
TRAEFIK_DASHBOARD_USER=$(env_format "$TRAEFIK_DASHBOARD_USER")
TRAEFIK_DASHBOARD_PASSWORD=$dashboard_password_line
EOF_TENV
    chmod 600 "$TRAEFIK_ENV"
}

write_oidc_env() {
    write_managed_file "$OIDC_ENV" "$TEMPLATE_OIDC_ENV" <<EOF_OIDC
$ROOT_OVERRIDE_MARKER
TURNSTONE_OIDC_ISSUER=$(env_format "$TURNSTONE_OIDC_ISSUER")
TURNSTONE_OIDC_CLIENT_ID=$(env_format "$TURNSTONE_OIDC_CLIENT_ID")
TURNSTONE_OIDC_CLIENT_SECRET=$(env_format "$TURNSTONE_OIDC_CLIENT_SECRET")
TURNSTONE_OIDC_SCOPES=$(env_format "$TURNSTONE_OIDC_SCOPES")
TURNSTONE_OIDC_PROVIDER_NAME=$(env_format "$TURNSTONE_OIDC_PROVIDER_NAME")
TURNSTONE_OIDC_ROLE_CLAIM=$(env_format "$TURNSTONE_OIDC_ROLE_CLAIM")
TURNSTONE_OIDC_ROLE_MAP=$(env_format "$TURNSTONE_OIDC_ROLE_MAP")
TURNSTONE_OIDC_PASSWORD_ENABLED=$(env_format "$TURNSTONE_OIDC_PASSWORD_ENABLED")
TURNSTONE_OIDC_REDIRECT_BASE=$(env_format "$TURNSTONE_OIDC_REDIRECT_BASE")
TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS=$(env_format "$TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS")
TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK=$(env_format "$TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK")
EOF_OIDC
    chmod 600 "$OIDC_ENV"
}

write_static_config() {
    write_managed_file "$TRAEFIK_CONFIG" "$TEMPLATE_CONFIG" <<EOF_CFG
$ROOT_OVERRIDE_MARKER
api:
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
providers:
  docker:
    endpoint: "http://docker-socket-proxy:2375"
    exposedByDefault: false
    network: turnstone-traefik
  file:
    directory: /etc/traefik/dynamic
    watch: true
certificatesResolvers:
  letsencrypt:
    acme:
      email: $TURNSTONE_TRAEFIK_ACME_EMAIL
      storage: /acme/acme.json
      dnsChallenge:
        provider: $TURNSTONE_TRAEFIK_DNS_PROVIDER
accessLog: {}
EOF_CFG
    chmod 600 "$TRAEFIK_CONFIG"
}

write_dynamic_auth() {
    local user_hash
    user_hash="$(hash_basic_auth "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD")"
    write_managed_file "$DYNAMIC_AUTH" <<EOF_AUTH
$ROOT_OVERRIDE_MARKER
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - "$(printf '%s' "$user_hash")"
EOF_AUTH
    chmod 600 "$DYNAMIC_AUTH"
}

write_root_override() {
    if [ -f "$ROOT_OVERRIDE" ] && ! is_managed_file "$ROOT_OVERRIDE"; then
        ask "Overwrite existing unmanaged file $ROOT_OVERRIDE?" n || die "Refusing to overwrite $ROOT_OVERRIDE."
    fi
    {
        echo "$ROOT_OVERRIDE_MARKER"
        cat "$TEMPLATE_OVERRIDE"
    } >"$ROOT_OVERRIDE"
    chmod 644 "$ROOT_OVERRIDE"
}

update_root_env_for_traefik() {
    set_env_key "$ROOT_ENV" TURNSTONE_TRAEFIK_APP_HOST "$TURNSTONE_TRAEFIK_APP_HOST"
    set_env_key "$ROOT_ENV" TURNSTONE_TRAEFIK_DASHBOARD_HOST "$TURNSTONE_TRAEFIK_DASHBOARD_HOST"
    chmod 600 "$ROOT_ENV"
}

fix_permissions() {
    chmod 600 "$ROOT_ENV" "$TRAEFIK_ENV" "$TRAEFIK_CONFIG" "$OIDC_ENV" "$ACME_FILE" "$DYNAMIC_AUTH" 2>/dev/null || true
}

build_image() {
    if [ "${TURNSTONE_SETUP_SKIP_BUILD:-}" = "1" ]; then
        info "Skipping docker compose build because TURNSTONE_SETUP_SKIP_BUILD=1."
        return
    fi
    info "Building the image (first run pulls dependencies — this can take a few minutes)…"
    (cd "$REPO_DIR" && $DOCKER compose build) || die "image build failed."
}

print_done() {
    cat <<EOF_DONE

${GREEN}${BOLD}Traefik deployment files are ready${RESET}

  Turnstone UI        ${BOLD}https://$TURNSTONE_TRAEFIK_APP_HOST${RESET}
  Traefik dashboard   ${BOLD}https://$TURNSTONE_TRAEFIK_DASHBOARD_HOST${RESET}
  Dashboard auth      ${BOLD}$TRAEFIK_DASHBOARD_USER${RESET} / ${BOLD}$TRAEFIK_DASHBOARD_PASSWORD${RESET}

  Next steps
    1. ${DIM}cd $REPO_DIR && $DOCKER compose up -d${RESET}
    2. Open ${BOLD}https://$TURNSTONE_TRAEFIK_APP_HOST${RESET} and create the first admin account,
       or sign in with the configured OIDC provider.
    3. Add LLM backends from the ${BOLD}Models${RESET} tab.

  Files
    - $ROOT_ENV
    - $ROOT_OVERRIDE
    - $NODE_OVERRIDE
    - $TRAEFIK_ENV
    - $TRAEFIK_CONFIG
    - $OIDC_ENV
    - $DYNAMIC_AUTH
    - $ACME_FILE
EOF_DONE
}

main() {
    printf '%s%sTurnstone Traefik setup%s\n\n' "$BOLD" "$GREEN" "$RESET"

    detect_os
    ensure_git
    ensure_docker_usable
    ensure_compose

    $DOCKER info 2>/dev/null | grep -qi 'rootless' && ROOTLESS=1 || ROOTLESS=0

    copy_templates
    prepare_root_env
    pick_node_count
    collect_inputs
    write_traefik_env
    write_oidc_env
    write_static_config
    write_dynamic_auth
    write_root_override
    write_node_override
    update_root_env_for_traefik
    fix_permissions
    build_image
    print_done
}

main "$@"
