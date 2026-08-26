#!/usr/bin/env bash
# Interactive builder for a Docker-based Turnstone deployment.
#
# Produces every file needed to run the stack in this folder:
#   compose.yaml            pulled production stack (ghcr.io images)
#   compose.override.yaml   deployment-specific service adjustments
#   tls.compose.yaml        service-to-service mTLS overlay (optional)
#   Caddyfile               browser TLS termination for the dashboard
#   caddy/Dockerfile        Caddy build with a DNS-challenge plugin (optional)
#   config/turnstone-oidc.env  OIDC single sign-on settings (optional)
#   workspace/              host directory the server nodes mount at /workspace
#   .env                    secrets and image tag
#
# After a successful run:  cd into this folder and `docker compose up -d`.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

SRC_COMPOSE="$REPO_DIR/turnstone/deploy/compose.yaml"
SRC_CADDYFILE="$REPO_DIR/turnstone/deploy/Caddyfile"
SRC_SEARXNG_DIR="$REPO_DIR/turnstone/deploy/searxng"
SRC_TLS_OVERLAY="$REPO_DIR/deploy/docker-compose.tls.yml"

OUT_COMPOSE="$SCRIPT_DIR/compose.yaml"
OUT_OVERRIDE="$SCRIPT_DIR/compose.override.yaml"
OUT_TLS_OVERLAY="$SCRIPT_DIR/tls.compose.yaml"
OUT_CADDYFILE="$SCRIPT_DIR/Caddyfile"
OUT_CADDY_DIR="$SCRIPT_DIR/caddy"
OUT_TRAEFIK_DIR="$SCRIPT_DIR/traefik"
OUT_TRAEFIK_DYNAMIC_DIR="$OUT_TRAEFIK_DIR/dynamic"
OUT_CONFIG_DIR="$SCRIPT_DIR/config"
OUT_OIDC_ENV="$OUT_CONFIG_DIR/turnstone-oidc.env"
OUT_SEARXNG_DIR="$SCRIPT_DIR/searxng"
OUT_ENV="$SCRIPT_DIR/.env"
OUT_ANSWERS="$SCRIPT_DIR/setup-production.env"
DEFAULT_WORKSPACE_DIR="$SCRIPT_DIR/workspace"

# Persistent answers file state. load_answers_file() sets AUTORUN from the
# file; write_answers_file() preserves it unchanged after a run.
AUTORUN="false"
declare -A _ANSWERS        # populated by each prompt helper during the run
declare -A _FILE_DEFAULTS  # answers-file values, used as prompt defaults
declare -A _EXISTING       # secrets recovered from previously generated files

IMAGE_REPO_API="https://api.github.com/repos/turnstonelabs/turnstone"
# Matches the image name in the source compose.yaml, so a locally built tag
# resolves from the daemon instead of a registry.
IMAGE_NAME="ghcr.io/turnstonelabs/turnstone"
LOCAL_IMAGE=0
PROJECT_NAME="turnstone"
PROXY_KIND="caddy"
MANAGED_TRAEFIK=0
EXTERNAL_PROXY_ENABLED=0

if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
info() { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# Returns true when the script must not attempt interactive prompts.
# /dev/tty can exist yet fail to open when there is no controlling terminal,
# so the check opens it rather than testing the file mode.
_no_tty() {
    [ "$AUTORUN" = "true" ] && return 0
    ( : </dev/tty ) 2>/dev/null || return 0
    return 1
}

on_error() {
    local rc=$?
    printf '\n%serror:%s setup-production.sh stopped unexpectedly (exit %s). Review the output above and re-run.\n' \
        "$RED" "$RESET" "$rc" >&2
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Prompt helpers. Every value is resolved through three precedence tiers
# (highest to lowest):
#   1. Environment variable exported by the user before invocation
#      (e.g. TURNSTONE_SETUP_OIDC=n ./setup-production.sh) — used as-is,
#      the prompt is skipped.
#   2. Value from the answers file (_FILE_DEFAULTS). With AUTORUN=true (or
#      no readable TTY) it is used as-is and the prompt is skipped; with
#      AUTORUN=false it only becomes the displayed default of the prompt.
#   3. Interactive prompt / built-in default.
# ---------------------------------------------------------------------------
ask() {
    local prompt="$1" envvar="$2" default="${3:-y}" ans hint
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        case "${!envvar}" in
            [Yy]*|1|true|TRUE) _ANSWERS["$envvar"]="y"; return 0 ;;
            *)                  _ANSWERS["$envvar"]="n"; return 1 ;;
        esac
    fi
    # Answers-file value becomes the default answer (tier 2/3).
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        case "${_FILE_DEFAULTS[$envvar]}" in
            [Yy]*|1|true|TRUE) default="y" ;;
            *)                 default="n" ;;
        esac
    fi
    [ "$default" = y ] && hint="Y/n" || hint="y/N"
    if _no_tty; then
        warn "non-interactive shell; assuming '$default' for: $prompt"
        if [ "$default" = y ]; then
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="y"; return 0
        else
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="n"; return 1
        fi
    fi
    printf '%s%s%s [%s] ' "$BOLD" "$prompt" "$RESET" "$hint" >/dev/tty
    read -r ans </dev/tty || ans=""
    ans="${ans:-$default}"
    case "$ans" in
        [Yy]*) [ -n "$envvar" ] && _ANSWERS["$envvar"]="y"; return 0 ;;
        *)     [ -n "$envvar" ] && _ANSWERS["$envvar"]="n"; return 1 ;;
    esac
}

prompt_value() {
    local outvar="$1" envvar="$2" prompt="$3" default="${4:-}" value=""
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        printf -v "$outvar" '%s' "${!envvar}"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="${!envvar}"
        return
    fi
    # Answers-file value becomes the bracketed default (tier 2/3).
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        default="${_FILE_DEFAULTS[$envvar]}"
    fi
    if _no_tty; then
        if [ -n "$default" ]; then
            warn "non-interactive shell; using default for: $prompt"
            printf -v "$outvar" '%s' "$default"
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="$default"
            return
        fi
        die "missing required input for: $prompt. Set ${envvar}."
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
            [ -n "$envvar" ] && _ANSWERS["$envvar"]="$value"
            return
        fi
        printf 'A value is required.\n' >/dev/tty
    done
}

prompt_optional() {
    local outvar="$1" envvar="$2" prompt="$3" default="" value=""
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        printf -v "$outvar" '%s' "${!envvar}"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="${!envvar}"
        return
    fi
    # Answers-file value becomes the bracketed default (tier 2/3).
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        default="${_FILE_DEFAULTS[$envvar]}"
    fi
    if _no_tty; then
        printf -v "$outvar" '%s' "$default"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="$default"
        return
    fi
    if [ -n "$default" ]; then
        printf '%s%s%s [%s]: ' "$BOLD" "$prompt" "$RESET" "$default" >/dev/tty
    else
        printf '%s%s%s [leave blank to skip]: ' "$BOLD" "$prompt" "$RESET" >/dev/tty
    fi
    read -r value </dev/tty || value=""
    value="${value:-$default}"
    printf -v "$outvar" '%s' "$value"
    [ -n "$envvar" ] && _ANSWERS["$envvar"]="$value"
}

prompt_choice() {
    # prompt_choice OUTVAR ENVVAR PROMPT DEFAULT CHOICE...
    local outvar="$1" envvar="$2" prompt="$3" default="$4" value choice
    shift 4
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        for choice in "$@"; do
            if [ "${!envvar}" = "$choice" ]; then
                printf -v "$outvar" '%s' "$choice"
                [ -n "$envvar" ] && _ANSWERS["$envvar"]="$choice"
                return
            fi
        done
        die "invalid value '${!envvar}' for ${envvar} (expected one of: $*)"
    fi
    # Answers-file value becomes the default choice (tier 2/3), validated
    # against the choice list so a stale/invalid file value cannot leak in.
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        local _fd_valid=0
        for choice in "$@"; do
            if [ "${_FILE_DEFAULTS[$envvar]}" = "$choice" ]; then
                _fd_valid=1
                break
            fi
        done
        if [ "$_fd_valid" = 1 ]; then
            default="${_FILE_DEFAULTS[$envvar]}"
        else
            warn "ignoring invalid answers-file value '${_FILE_DEFAULTS[$envvar]}' for ${envvar} (expected one of: $*)"
        fi
    fi
    if _no_tty; then
        warn "non-interactive shell; using default '$default' for: $prompt"
        printf -v "$outvar" '%s' "$default"
        [ -n "$envvar" ] && _ANSWERS["$envvar"]="$default"
        return
    fi
    while :; do
        printf '%s%s%s (%s) [%s]: ' "$BOLD" "$prompt" "$RESET" "$(IFS='/'; echo "$*")" "$default" >/dev/tty
        read -r value </dev/tty || value=""
        value="${value:-$default}"
        for choice in "$@"; do
            if [ "$value" = "$choice" ]; then
                printf -v "$outvar" '%s' "$choice"
                [ -n "$envvar" ] && _ANSWERS["$envvar"]="$choice"
                return
            fi
        done
        printf 'Choose one of: %s\n' "$*" >/dev/tty
    done
}

gen_hex() {
    if have openssl; then
        openssl rand -hex 32
    elif have python3; then
        python3 -c "import secrets; print(secrets.token_hex(32))"
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# Shows enough of a secret to recognise it without printing it in full.
mask_secret() {
    local v="$1" n=${#1}
    if [ "$n" -le 8 ]; then
        printf '•••• (%d chars)' "$n"
    else
        printf '%s…%s (%d chars)' "${v:0:4}" "${v: -4}" "$n"
    fi
}

_read_env_value() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 0
    line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
    [ -n "$line" ] || return 0
    printf '%s' "${line#*=}"
}

# Secrets already written by a previous run, offered back as "keep existing"
# so they never have to be retyped or stored in the answers file.
load_existing_secrets() {
    local k
    for k in TURNSTONE_JWT_SECRET POSTGRES_PASSWORD OPENAI_API_KEY CF_DNS_API_TOKEN \
             AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY DUCKDNS_API_TOKEN \
             TURNSTONE_DISCORD_TOKEN TURNSTONE_SLACK_TOKEN TURNSTONE_SLACK_APP_TOKEN \
             LLM_BASE_URL MODEL WORKSPACE_MOUNT; do
        _EXISTING["$k"]="$(_read_env_value "$OUT_ENV" "$k")"
    done
    # Deployments generated before the rename stored the model key here.
    if [ -z "${_EXISTING[OPENAI_API_KEY]:-}" ]; then
        _EXISTING[OPENAI_API_KEY]="$(_read_env_value "$OUT_ENV" LLAMA_API_KEY)"
    fi
    _EXISTING[TURNSTONE_OIDC_CLIENT_ID]="$(_read_env_value "$OUT_OIDC_ENV" TURNSTONE_OIDC_CLIENT_ID)"
    _EXISTING[TURNSTONE_OIDC_CLIENT_SECRET]="$(_read_env_value "$OUT_OIDC_ENV" TURNSTONE_OIDC_CLIENT_SECRET)"
    # Non-secret values recovered from a prior run become prompt defaults.
    local seed
    for seed in TURNSTONE_OIDC_CLIENT_ID LLM_BASE_URL MODEL; do
        if [ -z "${_FILE_DEFAULTS[$seed]:-}" ] && [ -n "${_EXISTING[$seed]:-}" ]; then
            _FILE_DEFAULTS["$seed"]="${_EXISTING[$seed]}"
        fi
    done
    # The workspace answer and the .env key it produces are named differently.
    if [ -z "${_FILE_DEFAULTS[TURNSTONE_SETUP_WORKSPACE_DIR]:-}" ] \
        && [ -n "${_EXISTING[WORKSPACE_MOUNT]:-}" ]; then
        _FILE_DEFAULTS[TURNSTONE_SETUP_WORKSPACE_DIR]="${_EXISTING[WORKSPACE_MOUNT]}"
    fi
}

# Like prompt_value, but resolves from an existing generated file and never
# records the value into the answers file.
prompt_secret() {
    local outvar="$1" envvar="$2" prompt="$3" exkey="${4:-$2}" existing=""
    if [ -n "$envvar" ] && [[ -v $envvar ]]; then
        printf -v "$outvar" '%s' "${!envvar}"
        return
    fi
    if [ -n "$envvar" ] && [ -n "${_FILE_DEFAULTS[$envvar]:-}" ]; then
        printf -v "$outvar" '%s' "${_FILE_DEFAULTS[$envvar]}"
        return
    fi
    existing="${_EXISTING[$exkey]:-}"
    if [ -n "$existing" ] && ask "Keep the existing $prompt ($(mask_secret "$existing"))?" "" y; then
        printf -v "$outvar" '%s' "$existing"
        return
    fi
    if _no_tty; then
        die "missing required secret for: $prompt. Export $envvar, or leave the previous value in $OUT_ENV."
    fi
    prompt_value "$outvar" "" "$prompt"
}

# ---------------------------------------------------------------------------
# Answers file: load prior answers (Bug fix: preserves existing secrets) and
# write current answers back after a successful run.
# ---------------------------------------------------------------------------

load_answers_file() {
    if [ ! -f "$OUT_ANSWERS" ]; then
        return
    fi
    local _line _key _value
    while IFS= read -r _line; do
        # Skip comments and blank lines.
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${_line//[[:space:]]/}" ]]  && continue
        [[ "$_line" == *=* ]] || continue
        _key="${_line%%=*}"
        _value="${_line#*=}"
        if [ "$_key" = "AUTORUN" ]; then
            AUTORUN="$_value"
            continue
        fi
        # Only load non-empty values. File values are kept separate from
        # the environment so they act as prompt defaults (precedence 2),
        # never masquerading as user-exported variables (precedence 1).
        if [ -n "$_value" ] && [ -n "$_key" ]; then
            _FILE_DEFAULTS["$_key"]="$_value"
        fi
    done <"$OUT_ANSWERS"
    if [ "$AUTORUN" = "true" ]; then
        info "AUTORUN=true: running non-interactively using $OUT_ANSWERS"
    fi
}

write_answers_file() {
    # Preserve the AUTORUN flag exactly as set by the user — never modify it.
    local _autorun="false"
    if [ -f "$OUT_ANSWERS" ]; then
        local _al
        while IFS= read -r _al; do
            if [[ "$_al" =~ ^AUTORUN=(.*)$ ]]; then
                _autorun="${BASH_REMATCH[1]}"
                break
            fi
        done <"$OUT_ANSWERS"
    fi
    info "Saving answers to $OUT_ANSWERS"
    local _a  # shorthand: print one answer line safely
    _a() { printf '%s=%s\n' "$1" "${_ANSWERS[$1]:-}"; }
    local _ab # secrets are referenced by source file, never copied in here
    _ab() { printf '%s=\n' "$1"; }
    (
        umask 177
        {
        cat <<'HDR'
# Turnstone production deployment answers file.
# Generated and updated by setup-production.sh after each successful run.
# Secrets are stored here — keep this file private (chmod 600, gitignored).
#
# AUTORUN flag
#   false (default): script prompts interactively; values below are pre-filled defaults.
#   true: fully non-interactive — all required values for enabled sections must be filled
#         in below; a missing required value causes an immediate error naming the variable.
#   Only YOU should change this flag; setup-production.sh never modifies it.
#
# Precedence (highest to lowest):
#   1. Exported shell environment variable  (e.g. TURNSTONE_SETUP_OIDC=n ./setup-production.sh)
#   2. Value in this file
#   3. Interactive prompt / built-in default
HDR
        printf 'AUTORUN=%s\n' "$_autorun"
        cat <<'S1'

# ---------------------------------------------------------------------------
# Deployment mode
# ---------------------------------------------------------------------------
# production or development  (default: production)
# Choosing development ends the script; use ./run.sh for the dev stack.
S1
        _a TURNSTONE_SETUP_MODE
        cat <<'S1B'

# ---------------------------------------------------------------------------
# Compose project name
# ---------------------------------------------------------------------------
# Give this deployment a custom project name?  Values: y | n  (default: n)
# The name prefixes every container, network, and volume. Changing it on an
# existing deployment starts from empty volumes.
S1B
        _a TURNSTONE_SETUP_CUSTOM_NAME
        printf '%s\n' "# Project name when CUSTOM_NAME=y  (default: turnstone)"
        _a TURNSTONE_SETUP_PROJECT_NAME
        cat <<'S1A'

# ---------------------------------------------------------------------------
# Image source
# ---------------------------------------------------------------------------
# Build the images from a source branch or use the prebuilt ghcr.io images.
# Values: build | prebuilt  (default: prebuilt)
S1A
        _a TURNSTONE_SETUP_IMAGE_SOURCE
        printf '%s\n' "# Branch to build when IMAGE_SOURCE=build.  Values: main | dev  (default: main)"
        _a TURNSTONE_SETUP_BUILD_BRANCH
        cat <<'S2'

# ---------------------------------------------------------------------------
# Image tag  (only when IMAGE_SOURCE=prebuilt)
# ---------------------------------------------------------------------------
# Track the rolling image or pin a release.  Values: latest | pinned  (default: latest)
S2
        _a TURNSTONE_SETUP_IMAGE_CHANNEL
        printf '%s\n' "# Specific release tag when IMAGE_CHANNEL=pinned (e.g. v1.2.3)."
        _a TURNSTONE_SETUP_IMAGE_TAG
        cat <<'S2A'

# ---------------------------------------------------------------------------
# Server nodes
# ---------------------------------------------------------------------------
# How many turnstone-server nodes to run. Positive integer  (default: 1)
S2A
        _a TURNSTONE_SETUP_NODE_COUNT
        cat <<'S2B'

# ---------------------------------------------------------------------------
# Workspace directory
# ---------------------------------------------------------------------------
# Host directory every server node mounts at /workspace. The final path
# component must be 'workspace'; any other path is treated as the parent and a
# 'workspace' directory is created inside it.
# (default: <this folder>/workspace)
S2B
        _a TURNSTONE_SETUP_WORKSPACE_DIR
        cat <<'S3'

# ---------------------------------------------------------------------------
# OIDC single sign-on (optional)
# ---------------------------------------------------------------------------
# Enable OIDC SSO?  Values: y | n  (default: n)
S3
        _a TURNSTONE_SETUP_OIDC
        printf '%s\n' "# Identity provider type.  Values: authentik | generic  (default: generic)"
        _a TURNSTONE_SETUP_OIDC_PROVIDER
        cat <<'S3A'
# --- Authentik path (only when OIDC_PROVIDER=authentik) ---
# Authentik base URL (e.g. https://authentik.example.com)
S3A
        _a TURNSTONE_SETUP_AUTHENTIK_URL
        printf '%s\n' "# Authentik application slug"
        _a TURNSTONE_SETUP_AUTHENTIK_SLUG
        cat <<'S3B'
# --- Generic path (only when OIDC_PROVIDER=generic) ---
# OIDC issuer URL (must serve /.well-known/openid-configuration)
S3B
        _a TURNSTONE_OIDC_ISSUER
        cat <<'S3C'
# --- Both provider paths ---
# OIDC client ID
S3C
        _a TURNSTONE_OIDC_CLIENT_ID
        printf '%s\n' "# OIDC client secret — kept in config/turnstone-oidc.env, not duplicated here"
        _ab TURNSTONE_OIDC_CLIENT_SECRET
        printf '%s\n' "# Login button label (generic only, default: SSO)"
        _a TURNSTONE_OIDC_PROVIDER_NAME
        printf '%s\n' "# OAuth scopes (generic only, default: openid email profile)"
        _a TURNSTONE_OIDC_SCOPES
        printf '%s\n' "# ID-token claim holding group/role values (generic only, default: groups)"
        _a TURNSTONE_OIDC_ROLE_CLAIM
        printf '%s\n' "# Claim value / group → Turnstone admin role  (default: admin / turnstone-admins)"
        _a TURNSTONE_SETUP_OIDC_ADMIN_VALUE
        printf '%s\n' "# Claim value / group → general user access  (default: users / turnstone-users)"
        _a TURNSTONE_SETUP_OIDC_USER_VALUE
        printf '%s\n' "# Extra trusted OIDC endpoint hostnames, comma-separated (optional, generic only)"
        _a TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS
        printf '%s\n' "# Public origin browsers use to reach Turnstone  (default: https://localhost:8443)"
        _a TURNSTONE_OIDC_REDIRECT_BASE
        printf '%s\n' "# Does the OIDC provider resolve to a private/internal address?  Values: y | n  (default: n)"
        _a TURNSTONE_SETUP_OIDC_PRIVATE
        printf '%s\n' "# Disable password logins once SSO works (SSO-only mode)?  Values: y | n  (default: n)"
        _a TURNSTONE_SETUP_OIDC_SSO_ONLY
        cat <<'S4'

# ---------------------------------------------------------------------------
# TLS (optional)
# ---------------------------------------------------------------------------
# Enable mutual TLS between Turnstone services?  Values: y | n  (default: n)
S4
        _a TURNSTONE_SETUP_TLS
        cat <<'S4P'

# ---------------------------------------------------------------------------
# Dashboard front end
# ---------------------------------------------------------------------------
# Reverse proxy that terminates browser HTTPS.  Values: caddy | traefik
# (default: caddy)
S4P
        _a TURNSTONE_SETUP_PROXY
        cat <<'S4T'
# --- Traefik settings (only when TURNSTONE_SETUP_PROXY=traefik) ---
# Deploy Traefik as part of this stack?  Values: y | n  (default: n)
# n means Traefik already runs on this system and only labels are generated.
S4T
        _a TURNSTONE_SETUP_TRAEFIK_INCLUDED
        printf '%s\n' "# Traefik router and service name  (default: turnstone)"
        _a TURNSTONE_SETUP_PROXY_ROUTER
        printf '%s\n' "# Docker network shared with Traefik  (external Traefik default: frontend;"
        printf '%s\n' "# bundled Traefik: optional extra network, blank for none)"
        _a TURNSTONE_SETUP_PROXY_NETWORK
        printf '%s\n' "# Traefik entrypoint  (external Traefik only, default: websecure)"
        _a TURNSTONE_SETUP_PROXY_ENTRYPOINT
        printf '%s\n' "# Traefik certresolver  (external Traefik only, blank if the entrypoint sets one)"
        _a TURNSTONE_SETUP_PROXY_CERT_RESOLVER
        printf '%s\n' "# Enable the Traefik web UI?  Values: y | n  (bundled Traefik + OIDC only, default: n)"
        _a TURNSTONE_SETUP_TRAEFIK_DASHBOARD
        printf '%s\n' "# Hostname for the Traefik web UI (e.g. traefik.example.com)"
        _a TURNSTONE_SETUP_TRAEFIK_DASHBOARD_HOST
        printf '%s\n' "# Forward-auth endpoint protecting the Traefik web UI"
        _a TURNSTONE_SETUP_TRAEFIK_FORWARD_AUTH
        printf '%s\n' "# Serve the dashboard at a public DNS name with a browser-trusted certificate?  Values: y | n  (default: n)"
        printf '%s\n' "# Caddy front end only."
        _a TURNSTONE_SETUP_PUBLIC_DNS
        cat <<'S4A'
# --- Hostname: used by the Traefik and public DNS paths alike ---
# Public hostname (e.g. turnstone.example.com)
S4A
        _a TURNSTONE_SETUP_DOMAIN
        printf '%s\n' "# Email address for Let's Encrypt registration"
        _a TURNSTONE_SETUP_ACME_EMAIL
        printf '%s\n' "# DNS challenge provider.  Values: cloudflare | route53 | duckdns  (default: cloudflare)"
        _a TURNSTONE_SETUP_DNS_PROVIDER
        printf '%s\n' "# Cloudflare DNS API token — kept in .env, not duplicated here  (cloudflare only)"
        _ab CF_DNS_API_TOKEN
        printf '%s\n' "# AWS access key ID for Route 53 DNS challenge  (route53 only)"
        _a TURNSTONE_SETUP_AWS_ACCESS_KEY_ID
        printf '%s\n' "# AWS secret access key — kept in .env, not duplicated here  (route53 only)"
        _ab TURNSTONE_SETUP_AWS_SECRET_ACCESS_KEY
        printf '%s\n' "# Duck DNS API token — kept in .env, not duplicated here  (duckdns only)"
        _ab TURNSTONE_SETUP_DUCKDNS_TOKEN
        cat <<'S5'

# ---------------------------------------------------------------------------
# LLM backend (optional)
# ---------------------------------------------------------------------------
# Configure a default LLM backend now?  Values: y | n  (default: n)
# Backends can also be connected later in the console Models tab.
S5
        _a TURNSTONE_SETUP_LLM
        printf '%s\n' "# OpenAI-compatible base URL  (default: http://host.docker.internal:8000/v1)"
        _a LLM_BASE_URL
        printf '%s\n' "# API key for the LLM backend — kept in .env, not duplicated here"
        _ab OPENAI_API_KEY
        printf '%s\n' "# Default model alias (optional, leave blank to skip)"
        _a MODEL
        cat <<'S6'

# ---------------------------------------------------------------------------
# Channel gateway (optional)
# ---------------------------------------------------------------------------
# Connect chat channels (Discord / Slack)?  Values: y | n  (default: n)
S6
        _a TURNSTONE_SETUP_CHANNELS
        printf '%s\n' "# Configure Discord?  Values: y | n  (default: n)"
        _a TURNSTONE_SETUP_DISCORD
        printf '%s\n' "# Discord bot token — kept in .env, not duplicated here  (Discord only)"
        _ab TURNSTONE_DISCORD_TOKEN
        printf '%s\n' "# Discord guild (server) ID  (Discord only, default: 0)"
        _a TURNSTONE_DISCORD_GUILD
        printf '%s\n' "# Configure Slack?  Values: y | n  (default: n)"
        _a TURNSTONE_SETUP_SLACK
        printf '%s\n' "# Slack bot token — kept in .env, not duplicated here  (Slack only)"
        _ab TURNSTONE_SLACK_TOKEN
        printf '%s\n' "# Slack app-level token — kept in .env, not duplicated here  (Slack only)"
        _ab TURNSTONE_SLACK_APP_TOKEN
        cat <<'S7'

# ---------------------------------------------------------------------------
# Secrets (normally generated automatically — only set these to pre-supply
# an existing value, e.g. to pair with an already-initialised data volume)
# ---------------------------------------------------------------------------
# Postgres password.
# Normally preserved automatically from .env and never written here. Set it
# only to pair a fresh deployment with an already-initialised data volume.
S7
        _ab POSTGRES_PASSWORD
        } >"$OUT_ANSWERS"
    )
    chmod 600 "$OUT_ANSWERS"
}

# ---------------------------------------------------------------------------
# .gitignore sync: every path this script generates in the working tree,
# appended to the repository-root .gitignore when not already ignored.
# ---------------------------------------------------------------------------
GITIGNORE_ENTRIES=(
    "override.compose.yaml"
    "deploy/auto-deployment/compose.yaml"
    "deploy/auto-deployment/compose.override.yaml"
    "deploy/auto-deployment/tls.compose.yaml"
    "deploy/auto-deployment/Caddyfile"
    "deploy/auto-deployment/caddy/"
    "deploy/auto-deployment/traefik/"
    "deploy/auto-deployment/config/"
    "deploy/auto-deployment/searxng/"
    "deploy/auto-deployment/workspace/"
    "deploy/auto-deployment/setup-production.env"
    "deploy/auto-deployment/.env"
)

# True when .gitignore already lists the exact pattern (bare or rooted).
_gitignore_has_line() {
    local gitignore="$1" entry="$2" line
    [ -f "$gitignore" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"   # strip leading blanks
        line="${line%"${line##*[![:space:]]}"}"   # strip trailing blanks
        [ -z "$line" ] && continue
        [ "${line:0:1}" = "#" ] && continue
        if [ "$line" = "$entry" ] || [ "$line" = "/$entry" ]; then
            return 0
        fi
    done <"$gitignore"
    return 1
}

# Appends every supplied pattern that is not already ignored.
ensure_gitignore_entries() {
    local gitignore="$REPO_DIR/.gitignore"
    local -a missing=()
    local entry

    for entry in "$@"; do
        _gitignore_has_line "$gitignore" "$entry" && continue
        # Skip entries an existing rule already ignores (e.g. a bare `.env`).
        if have git && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
            && git -C "$REPO_DIR" check-ignore -q "$entry" 2>/dev/null; then
            continue
        fi
        missing+=("$entry")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        info "Repository .gitignore already covers the requested paths."
        return 0
    fi

    if [ -e "$gitignore" ] && [ ! -w "$gitignore" ]; then
        warn "cannot update $gitignore (not writable); add these entries manually: ${missing[*]}"
        return 0
    fi

    info "Adding ${#missing[@]} entry/entries to $gitignore"
    # Command substitution drops a trailing newline: non-empty means the
    # file does not end with one, so start the block with a separator.
    local trailer=""
    if [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ]; then
        trailer=$'\n'
    fi
    {
        printf '%s\n# Generated by deploy/auto-deployment/setup-production.sh\n' "$trailer"
        printf '%s\n' "${missing[@]}"
    } >>"$gitignore"
}

check_prereqs() {
    have docker || die "docker is required. Install Docker Engine first: https://docs.docker.com/engine/install/"
    docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is required (docker compose version failed)."
    [ -f "$SRC_COMPOSE" ] || die "missing $SRC_COMPOSE — run this script from a full repository clone."
    [ -f "$SRC_CADDYFILE" ] || die "missing $SRC_CADDYFILE — run this script from a full repository clone."
    [ -d "$SRC_SEARXNG_DIR" ] || die "missing $SRC_SEARXNG_DIR — run this script from a full repository clone."
}

# ---------------------------------------------------------------------------
# Compose project name. It prefixes every container, network, and volume, so
# a second deployment can run beside the default one without colliding.
# ---------------------------------------------------------------------------
section_project_name() {
    PROJECT_NAME="turnstone"
    ask "Give this deployment a custom Compose project name?" TURNSTONE_SETUP_CUSTOM_NAME n || return 0
    while :; do
        prompt_value PROJECT_NAME TURNSTONE_SETUP_PROJECT_NAME \
            "Compose project name (lowercase letters, digits, '-' and '_')" "turnstone"
        [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] && break
        if [[ -v TURNSTONE_SETUP_PROJECT_NAME ]] || _no_tty; then
            die "invalid project name '$PROJECT_NAME' (lowercase letters, digits, '-' and '_'; must start with a letter or digit)"
        fi
        _FILE_DEFAULTS[TURNSTONE_SETUP_PROJECT_NAME]=""
        printf 'Use lowercase letters, digits, dashes, or underscores.\n' >/dev/tty
    done
    # Volumes are namespaced by project, so a rename starts from empty data.
    if [ "$PROJECT_NAME" != turnstone ] \
        && docker volume inspect turnstone_postgres-data >/dev/null 2>&1 \
        && ! docker volume inspect "${PROJECT_NAME}_postgres-data" >/dev/null 2>&1; then
        warn "project '$PROJECT_NAME' starts with empty volumes; the existing turnstone_postgres-data is left untouched."
    fi
}

# ---------------------------------------------------------------------------
# Image tag selection: track `latest` or pin a released tag. The pinned path
# resolves the newest release tag from the image source repository, with a
# manual fallback when the lookup is unavailable.
# ---------------------------------------------------------------------------
resolve_pinned_tag() {
    local tag=""
    if have curl; then
        tag="$(curl -fsS --max-time 10 "$IMAGE_REPO_API/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || tag=""
        if [ -z "$tag" ]; then
            tag="$(curl -fsS --max-time 10 "$IMAGE_REPO_API/tags?per_page=1" 2>/dev/null \
                | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" || tag=""
        fi
    fi
    printf '%s' "$tag"
}

section_image_tag() {
    local channel discovered
    prompt_choice channel TURNSTONE_SETUP_IMAGE_CHANNEL \
        "Track the rolling 'latest' image or pin a released tag?" latest latest pinned
    if [ "$channel" = latest ]; then
        IMAGE_TAG=latest
        return
    fi
    info "Looking up the newest released tag…"
    discovered="$(resolve_pinned_tag)"
    if [ -n "$discovered" ]; then
        prompt_value IMAGE_TAG TURNSTONE_SETUP_IMAGE_TAG "Image tag to pin" "$discovered"
    else
        warn "could not resolve a release tag automatically."
        prompt_value IMAGE_TAG TURNSTONE_SETUP_IMAGE_TAG "Image tag to pin (e.g. v1.2.3)"
    fi
}

# ---------------------------------------------------------------------------
# Source build: check out the selected branch into a throwaway worktree, build
# the Turnstone image from it, and pin the resulting tag into the stack.
# ---------------------------------------------------------------------------
build_images_from_source() {
    have git || die "git is required to build from source; choose 'prebuilt' instead."
    git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
        || die "$REPO_DIR is not a git repository; choose 'prebuilt' instead."
    [ -f "$REPO_DIR/Dockerfile" ] || die "missing $REPO_DIR/Dockerfile — build from a full repository clone."

    # Prefer the fetched remote head so the build tracks origin, not a stale
    # local branch; fall back to the local branch when the fetch is unavailable.
    local ref=""
    if git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
        info "Fetching origin/$BUILD_BRANCH…"
        if git -C "$REPO_DIR" fetch --quiet origin "$BUILD_BRANCH" 2>/dev/null; then
            ref="FETCH_HEAD"
        else
            warn "could not fetch origin/$BUILD_BRANCH; falling back to the local branch."
        fi
    fi
    if [ -z "$ref" ] && git -C "$REPO_DIR" rev-parse --verify --quiet "refs/heads/$BUILD_BRANCH" >/dev/null; then
        ref="refs/heads/$BUILD_BRANCH"
    fi
    [ -n "$ref" ] || die "branch '$BUILD_BRANCH' was not found locally or on origin."

    local sha short_sha
    sha="$(git -C "$REPO_DIR" rev-parse "$ref")" || die "could not resolve '$BUILD_BRANCH'."
    short_sha="${sha:0:7}"
    IMAGE_TAG="src-$BUILD_BRANCH-$short_sha"

    # Building from a detached worktree keeps the user's checkout and any
    # uncommitted work untouched.
    local tmp_root tree
    tmp_root="$(mktemp -d)" || die "mktemp -d failed while preparing the build tree."
    tree="$tmp_root/src"
    if ! git -C "$REPO_DIR" worktree add --quiet --detach "$tree" "$sha"; then
        rm -rf "$tmp_root"
        die "could not create a build worktree for '$BUILD_BRANCH'."
    fi

    info "Building $IMAGE_NAME:$IMAGE_TAG from $BUILD_BRANCH ($short_sha)…"
    local build_rc=0
    docker build -t "$IMAGE_NAME:$IMAGE_TAG" "$tree" || build_rc=$?
    git -C "$REPO_DIR" worktree remove --force "$tree" >/dev/null 2>&1 || true
    rm -rf "$tmp_root"
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
    [ "$build_rc" = 0 ] || die "docker build failed for branch '$BUILD_BRANCH' (exit $build_rc)."

    LOCAL_IMAGE=1
    info "Pinned the stack to the locally built $IMAGE_NAME:$IMAGE_TAG"
}

# ---------------------------------------------------------------------------
# Image provenance: build from a source branch, or take the prebuilt images
# and resolve their tag.
# ---------------------------------------------------------------------------
section_image_source() {
    local image_source
    prompt_choice image_source TURNSTONE_SETUP_IMAGE_SOURCE \
        "Build the Turnstone images from source or use prebuilt images?" prebuilt build prebuilt
    if [ "$image_source" != build ]; then
        section_image_tag
        return
    fi
    prompt_choice BUILD_BRANCH TURNSTONE_SETUP_BUILD_BRANCH \
        "Branch to build the images from" main main dev
    build_images_from_source
}

# ---------------------------------------------------------------------------
# Server node count. Node 1 is the base compose `server` service; any extra
# node is generated into compose.override.yaml with its own identity.
# ---------------------------------------------------------------------------
section_nodes() {
    while :; do
        prompt_value NODE_COUNT TURNSTONE_SETUP_NODE_COUNT \
            "How many turnstone-server nodes should this deployment run?" "1"
        [[ "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]] && return
        # Re-prompting cannot fix a bad exported/non-interactive value.
        if [[ -v TURNSTONE_SETUP_NODE_COUNT ]] || _no_tty; then
            die "node count must be a positive integer (got '$NODE_COUNT')"
        fi
        _FILE_DEFAULTS[TURNSTONE_SETUP_NODE_COUNT]=""
        printf 'Enter a positive whole number.\n' >/dev/tty
    done
}

# ---------------------------------------------------------------------------
# Workspace directory. Every server node bind-mounts one host directory at
# /workspace, and both the mount and the terminology are fixed to that name,
# so the host path must end in `workspace`. A path ending in anything else is
# taken as the parent that holds it.
# ---------------------------------------------------------------------------
section_workspace() {
    local answer
    info "The workspace directory is mounted into every server node at /workspace."
    info "It must be named 'workspace'; any other path is used as the parent and a 'workspace' directory is created inside it."
    prompt_value answer TURNSTONE_SETUP_WORKSPACE_DIR \
        "Host directory for the Turnstone workspace" "$DEFAULT_WORKSPACE_DIR"

    answer="${answer/#\~/$HOME}"
    while [ "${#answer}" -gt 1 ] && [ "${answer%/}" != "$answer" ]; do
        answer="${answer%/}"
    done
    # A relative answer resolves against this folder, not the caller's cwd.
    case "$answer" in
        /*) ;;
        *) answer="$SCRIPT_DIR/$answer" ;;
    esac
    if [ "$(basename "$answer")" = workspace ]; then
        WORKSPACE_DIR="$answer"
    else
        WORKSPACE_DIR="$answer/workspace"
    fi

    local mkdir_err
    if [ -d "$WORKSPACE_DIR" ]; then
        info "Using the existing workspace directory $WORKSPACE_DIR"
    elif [ -e "$WORKSPACE_DIR" ]; then
        die "$WORKSPACE_DIR exists but is not a directory; choose another location."
    elif mkdir_err="$(mkdir -p "$WORKSPACE_DIR" 2>&1)"; then
        info "Workspace folder was created at $WORKSPACE_DIR"
    else
        # mkdir fails when a parent is not writable, which no answer can fix:
        # the directory has to be created and handed over out of band.
        printf '\n%swarning:%s the workspace directory could not be created at %s\n' \
            "$YELLOW" "$RESET" "$WORKSPACE_DIR" >&2
        [ -n "$mkdir_err" ] && printf '  %s\n' "$mkdir_err" >&2
        printf 'Create it yourself and take ownership, then re-run this script:\n\n' >&2
        printf '    sudo mkdir -p %s\n' "$WORKSPACE_DIR" >&2
        printf '    sudo chown %s:%s %s\n\n' "$(id -u)" "$(id -g)" "$WORKSPACE_DIR" >&2
        die "cannot create the workspace directory $WORKSPACE_DIR"
    fi

    # The recorded answer is the resolved path, so a rerun offers the directory
    # actually in use rather than the parent that was typed.
    _ANSWERS[TURNSTONE_SETUP_WORKSPACE_DIR]="$WORKSPACE_DIR"
    ensure_workspace_gitignore
}

# A workspace placed inside the clone would otherwise show every file an agent
# writes as untracked repository content.
ensure_workspace_gitignore() {
    case "$WORKSPACE_DIR/" in
        "$REPO_DIR"/*) ;;
        *) return 0 ;;
    esac
    local rel="${WORKSPACE_DIR#"$REPO_DIR"/}/"
    _gitignore_has_line "$REPO_DIR/.gitignore" "$rel" && return 0
    ensure_gitignore_entries "$rel"
}

# ---------------------------------------------------------------------------
# OIDC single sign-on. The Authentik path asks only for what an Authentik
# provider needs; role claims map an admin group and a general-users group
# onto the built-in Turnstone roles.
# ---------------------------------------------------------------------------
section_oidc() {
    OIDC_ENABLED=0
    ask "Enable OIDC single sign-on?" TURNSTONE_SETUP_OIDC n || return 0
    OIDC_ENABLED=1

    local provider
    prompt_choice provider TURNSTONE_SETUP_OIDC_PROVIDER \
        "Identity provider type" generic authentik generic

    if [ "$provider" = authentik ]; then
        local ak_base ak_slug
        info "Register Turnstone in Authentik as a confidential OAuth2/OpenID provider first."
        info "Redirect URI to register: <public origin>/v1/api/auth/oidc/callback"
        prompt_value ak_base TURNSTONE_SETUP_AUTHENTIK_URL "Authentik base URL (e.g. https://authentik.example.com)"
        ak_base="${ak_base%/}"
        prompt_value ak_slug TURNSTONE_SETUP_AUTHENTIK_SLUG "Authentik application slug"
        OIDC_ISSUER="$ak_base/application/o/$ak_slug/"
        OIDC_PROVIDER_NAME="Authentik"
        OIDC_SCOPES="openid email profile"
        # Authentik exposes group membership through the `groups` claim.
        OIDC_ROLE_CLAIM="groups"
        prompt_value OIDC_CLIENT_ID TURNSTONE_OIDC_CLIENT_ID "Authentik client ID"
        prompt_secret OIDC_CLIENT_SECRET TURNSTONE_OIDC_CLIENT_SECRET "Authentik client secret"
        local admin_group user_group
        prompt_value admin_group TURNSTONE_SETUP_OIDC_ADMIN_VALUE "Authentik group granted the Turnstone admin role" "turnstone-admins"
        prompt_value user_group TURNSTONE_SETUP_OIDC_USER_VALUE "Authentik group granted general user access" "turnstone-users"
        OIDC_ROLE_MAP="$admin_group:builtin-admin,$user_group:builtin-operator"
        OIDC_TRUSTED_HOSTS=""
    else
        prompt_value OIDC_ISSUER TURNSTONE_OIDC_ISSUER "OIDC issuer URL (must serve /.well-known/openid-configuration)"
        prompt_value OIDC_CLIENT_ID TURNSTONE_OIDC_CLIENT_ID "OIDC client ID"
        prompt_secret OIDC_CLIENT_SECRET TURNSTONE_OIDC_CLIENT_SECRET "OIDC client secret"
        prompt_value OIDC_PROVIDER_NAME TURNSTONE_OIDC_PROVIDER_NAME "Login button label" "SSO"
        prompt_value OIDC_SCOPES TURNSTONE_OIDC_SCOPES "OAuth scopes" "openid email profile"
        prompt_value OIDC_ROLE_CLAIM TURNSTONE_OIDC_ROLE_CLAIM "ID-token claim holding group/role values" "groups"
        local admin_value user_value
        prompt_value admin_value TURNSTONE_SETUP_OIDC_ADMIN_VALUE "Claim value granted the Turnstone admin role" "admin"
        prompt_value user_value TURNSTONE_SETUP_OIDC_USER_VALUE "Claim value granted general user access" "users"
        OIDC_ROLE_MAP="$admin_value:builtin-admin,$user_value:builtin-operator"
        prompt_optional OIDC_TRUSTED_HOSTS TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS \
            "Extra trusted endpoint hostnames (comma-separated)"
    fi

    prompt_value OIDC_REDIRECT_BASE TURNSTONE_OIDC_REDIRECT_BASE \
        "Public origin browsers use to reach Turnstone (e.g. https://turnstone.example.com)" \
        "https://localhost:8443"
    OIDC_REDIRECT_BASE="${OIDC_REDIRECT_BASE%/}"

    OIDC_ALLOW_PRIVATE=false
    if ask "Does the identity provider resolve to a private/internal address?" TURNSTONE_SETUP_OIDC_PRIVATE n; then
        OIDC_ALLOW_PRIVATE=true
    fi
    OIDC_PASSWORD_ENABLED=true
    if ask "Disable password logins once SSO works (SSO-only mode)?" TURNSTONE_SETUP_OIDC_SSO_ONLY n; then
        OIDC_PASSWORD_ENABLED=false
    fi
}

# ---------------------------------------------------------------------------
# TLS and the dashboard front end: mTLS overlay first, then the reverse proxy
# that terminates browser HTTPS — bundled Caddy, a Traefik deployed with this
# stack, or a Traefik already running on the host.
# ---------------------------------------------------------------------------
section_tls() {
    MTLS_ENABLED=0
    PUBLIC_DNS_ENABLED=0
    EXTERNAL_PROXY_ENABLED=0
    MANAGED_TRAEFIK=0
    PROXY_KIND="caddy"
    PROXY_NETWORK=""
    PROXY_ROUTER=""
    PROXY_ENTRYPOINT=""
    PROXY_CERT_RESOLVER=""
    TRAEFIK_DASHBOARD=0
    TRAEFIK_DASHBOARD_HOST=""
    TRAEFIK_FORWARD_AUTH=""
    DOMAIN=""
    DNS_PROVIDER=""
    ACME_EMAIL=""
    CF_TOKEN=""
    AWS_KEY_ID=""
    AWS_SECRET=""
    DUCKDNS_TOKEN_VAL=""

    if ask "Enable TLS (mutual TLS between Turnstone services)?" TURNSTONE_SETUP_TLS n; then
        MTLS_ENABLED=1
    fi

    prompt_choice PROXY_KIND TURNSTONE_SETUP_PROXY \
        "Which reverse proxy should serve the dashboard?" caddy caddy traefik
    if [ "$PROXY_KIND" = caddy ]; then
        section_caddy_frontend
        return 0
    fi

    if ask "Deploy Traefik as part of this stack? (No = Traefik already runs on this system)" \
        TURNSTONE_SETUP_TRAEFIK_INCLUDED n; then
        MANAGED_TRAEFIK=1
        section_traefik_managed
    else
        EXTERNAL_PROXY_ENABLED=1
        section_traefik_external
    fi
}

# Turnstone only publishes labels; another stack owns Traefik and the ports.
section_traefik_external() {
    prompt_value DOMAIN TURNSTONE_SETUP_DOMAIN \
        "Hostname Traefik serves Turnstone at (e.g. turnstone.example.com)"
    prompt_value PROXY_NETWORK TURNSTONE_SETUP_PROXY_NETWORK \
        "Existing Docker network shared with Traefik" "frontend"
    prompt_value PROXY_ROUTER TURNSTONE_SETUP_PROXY_ROUTER \
        "Traefik router and service name" "turnstone"
    prompt_value PROXY_ENTRYPOINT TURNSTONE_SETUP_PROXY_ENTRYPOINT \
        "Traefik entrypoint" "websecure"
    prompt_optional PROXY_CERT_RESOLVER TURNSTONE_SETUP_PROXY_CERT_RESOLVER \
        "Traefik certresolver (blank if the entrypoint already sets one)"
    if ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
        warn "Docker network '$PROXY_NETWORK' does not exist yet — create it before starting the stack: docker network create $PROXY_NETWORK"
    fi
}

# Traefik ships inside this stack, so it also needs ACME and dashboard answers.
section_traefik_managed() {
    prompt_value DOMAIN TURNSTONE_SETUP_DOMAIN \
        "Hostname Traefik should serve Turnstone at (e.g. turnstone.example.com)"
    prompt_value PROXY_ROUTER TURNSTONE_SETUP_PROXY_ROUTER \
        "Traefik router and service name" "turnstone"
    prompt_value ACME_EMAIL TURNSTONE_SETUP_ACME_EMAIL "Email address for Let's Encrypt registration"
    prompt_choice DNS_PROVIDER TURNSTONE_SETUP_DNS_PROVIDER \
        "DNS challenge provider" cloudflare cloudflare route53 duckdns
    section_dns_credentials
    PROXY_ENTRYPOINT="websecure"
    PROXY_CERT_RESOLVER="$DNS_PROVIDER"
    prompt_optional PROXY_NETWORK TURNSTONE_SETUP_PROXY_NETWORK \
        "Additional existing Docker network for Traefik to serve other stacks on"
    if [ -n "$PROXY_NETWORK" ] && ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
        warn "Docker network '$PROXY_NETWORK' does not exist yet — create it before starting the stack: docker network create $PROXY_NETWORK"
    fi

    # The dashboard is only offered when SSO can front it with forward auth.
    if [ "$OIDC_ENABLED" != 1 ]; then
        warn "OIDC is not configured, so the Traefik web UI stays disabled — it would be reachable without authentication."
        return 0
    fi
    ask "Enable the Traefik web UI (dashboard)?" TURNSTONE_SETUP_TRAEFIK_DASHBOARD n || return 0
    TRAEFIK_DASHBOARD=1
    prompt_value TRAEFIK_DASHBOARD_HOST TURNSTONE_SETUP_TRAEFIK_DASHBOARD_HOST \
        "Hostname for the Traefik web UI (e.g. traefik.example.com)"
    prompt_value TRAEFIK_FORWARD_AUTH TURNSTONE_SETUP_TRAEFIK_FORWARD_AUTH \
        "Forward-auth endpoint protecting the web UI" \
        "http://authentik-outpost:9000/outpost.goauthentik.io/auth/traefik"
}

# Bundled Caddy: local CA by default, or a public Let's Encrypt certificate.
section_caddy_frontend() {
    ask "Serve the dashboard on a public DNS name with a browser-trusted certificate?" TURNSTONE_SETUP_PUBLIC_DNS n || return 0
    PUBLIC_DNS_ENABLED=1

    prompt_value DOMAIN TURNSTONE_SETUP_DOMAIN "Public DNS name Turnstone should be reachable at (e.g. turnstone.example.com)"
    prompt_value ACME_EMAIL TURNSTONE_SETUP_ACME_EMAIL "Email address for Let's Encrypt registration"
    prompt_choice DNS_PROVIDER TURNSTONE_SETUP_DNS_PROVIDER \
        "DNS challenge provider" cloudflare cloudflare route53 duckdns
    section_dns_credentials

    # The public-DNS path builds a local Caddy image with the DNS plugin.
    # Compose builds with buildx when available; without it, it falls back
    # to the deprecated classic builder (slower, prints a WARN, and will be
    # removed in a future Docker release).
    if ! docker buildx version >/dev/null 2>&1; then
        warn "the Docker buildx plugin is not installed; 'docker compose up' will fall back to the legacy builder to build the Caddy DNS image. Install docker-buildx-plugin to silence the compose WARN: https://docs.docker.com/build/install-buildx/"
    fi
}

section_dns_credentials() {
    case "$DNS_PROVIDER" in
        cloudflare)
            prompt_secret CF_TOKEN CF_DNS_API_TOKEN "Cloudflare DNS API token (Zone:DNS:Edit for the domain)"
            ;;
        route53)
            prompt_value AWS_KEY_ID TURNSTONE_SETUP_AWS_ACCESS_KEY_ID "AWS access key ID (Route 53 change-record permissions)"
            prompt_secret AWS_SECRET TURNSTONE_SETUP_AWS_SECRET_ACCESS_KEY "AWS secret access key" AWS_SECRET_ACCESS_KEY
            ;;
        duckdns)
            prompt_secret DUCKDNS_TOKEN_VAL TURNSTONE_SETUP_DUCKDNS_TOKEN "Duck DNS API token" DUCKDNS_API_TOKEN
            ;;
    esac
}

# ---------------------------------------------------------------------------
# LLM backend bootstrap defaults. Real backends can also be connected later
# from the console Models tab.
# ---------------------------------------------------------------------------
section_llm() {
    LLM_ENABLED=0
    ask "Configure a default LLM backend now?" TURNSTONE_SETUP_LLM n || return 0
    LLM_ENABLED=1
    prompt_value LLM_BASE_URL_VAL LLM_BASE_URL "OpenAI-compatible base URL" "http://host.docker.internal:8000/v1"
    prompt_secret LLM_API_KEY OPENAI_API_KEY "API key for the backend"
    prompt_optional LLM_MODEL MODEL "Default model alias"
}

# ---------------------------------------------------------------------------
# Channel gateway (Discord and/or Slack). Runs idle when no token is set.
# ---------------------------------------------------------------------------
section_channels() {
    CHANNELS_ENABLED=0
    DISCORD_TOKEN=""
    DISCORD_GUILD="0"
    SLACK_TOKEN=""
    SLACK_APP_TOKEN=""
    ask "Connect chat channels (Discord / Slack)?" TURNSTONE_SETUP_CHANNELS n || return 0
    CHANNELS_ENABLED=1
    if ask "Configure Discord?" TURNSTONE_SETUP_DISCORD n; then
        prompt_secret DISCORD_TOKEN TURNSTONE_DISCORD_TOKEN "Discord bot token"
        prompt_value DISCORD_GUILD TURNSTONE_DISCORD_GUILD "Discord guild (server) ID" "0"
    fi
    if ask "Configure Slack?" TURNSTONE_SETUP_SLACK n; then
        prompt_secret SLACK_TOKEN TURNSTONE_SLACK_TOKEN "Slack bot token (xoxb-…)"
        prompt_secret SLACK_APP_TOKEN TURNSTONE_SLACK_APP_TOKEN "Slack app-level token (xapp-…)"
    fi
}

# ---------------------------------------------------------------------------
# File generation
# ---------------------------------------------------------------------------
copy_stack_files() {
    info "Copying the production stack files into $SCRIPT_DIR"
    cp "$SRC_COMPOSE" "$OUT_COMPOSE"
    rm -rf "$OUT_SEARXNG_DIR"
    mkdir -p "$OUT_SEARXNG_DIR"
    cp "$SRC_SEARXNG_DIR"/* "$OUT_SEARXNG_DIR/"
    if [ "$MTLS_ENABLED" = 1 ]; then
        cp "$SRC_TLS_OVERLAY" "$OUT_TLS_OVERLAY"
        sanitize_tls_overlay
    else
        rm -f "$OUT_TLS_OVERLAY"
    fi
}

# The upstream TLS overlay overrides the console service command with a
# `--poll-interval` flag that the current turnstone-console CLI no longer
# accepts, which crash-loops the console ("unrecognized arguments").
# Dropping the whole `command:` override is safe: without it the console
# falls back to the base compose command (turnstone-console
# --host=0.0.0.0 --port=8090), which is exactly what the override ran.
#
# The removal is structure-aware (YAML indentation based), not tied to
# line numbers or file order, so it keeps working if the upstream file
# is reordered, reformatted, or grows/shrinks. It only touches the
# `command:` key of the `console:` service under `services:` — every
# other service (e.g. tls-init, channel) keeps its command untouched.
sanitize_tls_overlay() {
    [ -f "$OUT_TLS_OVERLAY" ] || die "TLS overlay $OUT_TLS_OVERLAY is missing; the copy from $SRC_TLS_OVERLAY failed"
    local tmp
    tmp="$(mktemp)" || die "mktemp failed while sanitizing $OUT_TLS_OVERLAY"
    if ! awk '
        BEGIN { in_services = 0; in_console = 0; skipping = 0; blanks = 0 }
        function indent_of(line,    n) {
            n = 0
            while (substr(line, n + 1, 1) == " ") n++
            return n
        }
        {
            line = $0
            trimmed = line
            sub(/^[ \t]+/, "", trimmed)
            is_blank = (trimmed == "")
            is_comment = (substr(trimmed, 1, 1) == "#")
            is_content = (!is_blank && !is_comment)
            ind = indent_of(line)

            # While removing the console command block: swallow every line
            # indented deeper than the `command:` key. Blank lines are held
            # back until we know whether the block continues after them.
            if (skipping) {
                if (is_blank) { blanks++; next }
                if (ind > cmd_indent) { blanks = 0; next }
                skipping = 0
                while (blanks > 0) { print ""; blanks-- }
            }

            # Leave the console service / services section when a content
            # line appears at the same or shallower indentation.
            if (in_console && is_content && ind <= console_indent) in_console = 0
            if (in_services && is_content && ind <= services_indent) in_services = 0

            if (is_content && ind == 0 && trimmed ~ /^services:[ \t]*(#.*)?$/) {
                in_services = 1
                services_indent = ind
            } else if (in_services && !in_console && is_content && trimmed ~ /^console:[ \t]*(#.*)?$/) {
                in_console = 1
                console_indent = ind
            } else if (in_console && is_content && trimmed ~ /^command:([ \t].*)?$/) {
                skipping = 1
                cmd_indent = ind
                blanks = 0
                next
            }
            print
        }
    ' "$OUT_TLS_OVERLAY" >"$tmp"; then
        rm -f "$tmp"
        die "Failed to sanitize $OUT_TLS_OVERLAY"
    fi
    mv "$tmp" "$OUT_TLS_OVERLAY"
    # Belt and braces: the removed override carried the unsupported
    # --poll-interval flag. If it is still present the console would
    # crash-loop, so fail loudly rather than deploy a broken stack.
    if grep -q -- '--poll-interval' "$OUT_TLS_OVERLAY"; then
        die "Sanitizing $OUT_TLS_OVERLAY failed: unsupported --poll-interval flag is still present"
    fi
}

write_caddyfile() {
    if [ "$PUBLIC_DNS_ENABLED" != 1 ]; then
        cp "$SRC_CADDYFILE" "$OUT_CADDYFILE"
        rm -rf "$OUT_CADDY_DIR"
        return
    fi

    local tls_line
    case "$DNS_PROVIDER" in
        cloudflare) tls_line="dns cloudflare {env.CF_DNS_API_TOKEN}" ;;
        route53)    tls_line="dns route53" ;;
        duckdns)    tls_line="dns duckdns {env.DUCKDNS_API_TOKEN}" ;;
    esac

    # Public HTTPS: Let's Encrypt certificate via DNS-01, dashboard on 443.
    cat >"$OUT_CADDYFILE" <<EOF
{
	email $ACME_EMAIL
}

$DOMAIN {
	tls {
		$tls_line
	}
	reverse_proxy console:8090 {
		flush_interval -1
	}
}
EOF

    # The stock Caddy image ships no DNS plugins; build one in.
    mkdir -p "$OUT_CADDY_DIR"
    cat >"$OUT_CADDY_DIR/Dockerfile" <<EOF
FROM caddy:2.11-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/$DNS_PROVIDER
FROM caddy:2.11
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF
}

# Static and dynamic Traefik config, written only when Traefik ships with the
# stack. The web UI stays off unless forward auth can protect it.
write_traefik_config() {
    if [ "$MANAGED_TRAEFIK" != 1 ]; then
        rm -rf "$OUT_TRAEFIK_DIR"
        return
    fi
    mkdir -p "$OUT_TRAEFIK_DYNAMIC_DIR" "$OUT_TRAEFIK_DIR/certs"

    {
        cat <<EOF
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO

entryPoints:
  web:
    address: :80
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: :443
    http:
      tls:
        certResolver: $DNS_PROVIDER

certificatesResolvers:
  $DNS_PROVIDER:
    acme:
      email: $ACME_EMAIL
      storage: /var/traefik/certs/$DNS_PROVIDER-acme.json
      caServer: "https://acme-v02.api.letsencrypt.org/directory"
      dnsChallenge:
        provider: $DNS_PROVIDER
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: ${PROJECT_NAME}_turnstone-net
  file:
    directory: /etc/traefik/dynamic
    watch: true

api:
EOF
        if [ "$TRAEFIK_DASHBOARD" = 1 ]; then
            printf '  dashboard: true\n  insecure: false\n'
        else
            printf '  # The Traefik web UI needs proxy protection before being enabled.\n'
            printf '  dashboard: false\n  insecure: false\n'
        fi
    } >"$OUT_TRAEFIK_DIR/traefik.yaml"

    if [ "$TRAEFIK_DASHBOARD" = 1 ]; then
        cat >"$OUT_TRAEFIK_DYNAMIC_DIR/middlewares.yaml" <<EOF
http:
  middlewares:
    dashboard-auth:
      forwardAuth:
        address: $TRAEFIK_FORWARD_AUTH
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-email
          - X-authentik-name
          - X-authentik-uid
EOF
    else
        rm -f "$OUT_TRAEFIK_DYNAMIC_DIR/middlewares.yaml"
    fi
}

_traefik_console_labels() {
    local net="$1"
    printf '    labels:\n'
    printf '      - "traefik.enable=true"\n'
    printf '      - "traefik.docker.network=%s"\n' "$net"
    printf '      - "traefik.http.routers.%s.rule=Host(`%s`)"\n' "$PROXY_ROUTER" "$DOMAIN"
    printf '      - "traefik.http.routers.%s.entrypoints=%s"\n' "$PROXY_ROUTER" "$PROXY_ENTRYPOINT"
    printf '      - "traefik.http.routers.%s.tls=true"\n' "$PROXY_ROUTER"
    if [ -n "$PROXY_CERT_RESOLVER" ]; then
        printf '      - "traefik.http.routers.%s.tls.certresolver=%s"\n' "$PROXY_ROUTER" "$PROXY_CERT_RESOLVER"
    fi
    printf '      - "traefik.http.routers.%s.service=%s"\n' "$PROXY_ROUTER" "$PROXY_ROUTER"
    printf '      - "traefik.http.services.%s.loadbalancer.server.port=8090"\n' "$PROXY_ROUTER"
}

_traefik_service_block() {
    cat <<EOF
  traefik:
    image: traefik:v3.7
    container_name: ${PROJECT_NAME}-traefik
    depends_on:
      - console
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yaml:/etc/traefik/traefik.yaml:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
      - ./traefik/certs:/var/traefik/certs:rw
    networks:
      - turnstone-net
EOF
    if [ -n "$PROXY_NETWORK" ]; then
        printf '      - %s\n' "$PROXY_NETWORK"
    fi
    printf '    environment:\n'
    case "$DNS_PROVIDER" in
        cloudflare) printf '      CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}\n' ;;
        route53)    printf '      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}\n      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}\n' ;;
        duckdns)    printf '      DUCKDNS_TOKEN: ${DUCKDNS_TOKEN}\n' ;;
    esac
    if [ "$TRAEFIK_DASHBOARD" = 1 ]; then
        printf '    labels:\n'
        printf '      - "traefik.enable=true"\n'
        printf '      - "traefik.docker.network=%s"\n' "${PROJECT_NAME}_turnstone-net"
        printf '      - "traefik.http.routers.dashboard.rule=Host(`%s`)"\n' "$TRAEFIK_DASHBOARD_HOST"
        printf '      - "traefik.http.routers.dashboard.entrypoints=websecure"\n'
        printf '      - "traefik.http.routers.dashboard.tls=true"\n'
        printf '      - "traefik.http.routers.dashboard.tls.certresolver=%s"\n' "$DNS_PROVIDER"
        printf '      - "traefik.http.routers.dashboard.service=api@internal"\n'
        printf '      - "traefik.http.routers.dashboard.middlewares=dashboard-auth@file"\n'
    fi
    printf '    restart: unless-stopped\n'
}

write_oidc_env() {
    if [ "$OIDC_ENABLED" != 1 ]; then
        rm -f "$OUT_OIDC_ENV"
        return
    fi
    mkdir -p "$OUT_CONFIG_DIR"
    cat >"$OUT_OIDC_ENV" <<EOF
TURNSTONE_OIDC_ISSUER=$OIDC_ISSUER
TURNSTONE_OIDC_CLIENT_ID=$OIDC_CLIENT_ID
TURNSTONE_OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET
TURNSTONE_OIDC_SCOPES=$OIDC_SCOPES
TURNSTONE_OIDC_PROVIDER_NAME=$OIDC_PROVIDER_NAME
TURNSTONE_OIDC_ROLE_CLAIM=$OIDC_ROLE_CLAIM
TURNSTONE_OIDC_ROLE_MAP=$OIDC_ROLE_MAP
TURNSTONE_OIDC_REDIRECT_BASE=$OIDC_REDIRECT_BASE
TURNSTONE_OIDC_PASSWORD_ENABLED=$OIDC_PASSWORD_ENABLED
TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK=$OIDC_ALLOW_PRIVATE
TURNSTONE_OIDC_TRUSTED_ENDPOINT_HOSTS=$OIDC_TRUSTED_HOSTS
EOF
    chmod 600 "$OUT_OIDC_ENV"
}

# Nodes 2…N. Each extends the base `server` service and overrides only its
# own identity. `extends` does not carry depends_on, so it is restated here.
write_extra_nodes() {
    local i
    for ((i = 2; i <= NODE_COUNT; i++)); do
        cat <<EOF
  server-$i:
    extends:
      file: compose.yaml
      service: server
EOF
        # `extends` pulls from compose.yaml, so the override's pull_policy
        # does not reach these nodes and is restated here.
        if [ "$LOCAL_IMAGE" = 1 ]; then
            printf '    pull_policy: never\n'
        fi
        cat <<EOF
    environment:
      TURNSTONE_NODE_ID: node-$i
      TURNSTONE_ADVERTISE_URL: http://server-$i:8080
EOF
        if [ "$MTLS_ENABLED" = 1 ]; then
            cat <<EOF
      TURNSTONE_TLS_ENABLED: "true"
      TURNSTONE_TLS_SANS: server-$i
EOF
        fi
        if [ "$OIDC_ENABLED" = 1 ]; then
            cat <<'EOF'
    env_file:
      - ./config/turnstone-oidc.env
EOF
        fi
        cat <<'EOF'
    depends_on:
      postgres:
        condition: service_healthy
      searxng:
        condition: service_healthy
EOF
        if [ "$MTLS_ENABLED" = 1 ]; then
            # Mirrors tls.compose.yaml's `server` patch: the node enrolls its
            # cert through the console and then only speaks mTLS, which the
            # plain-HTTP healthcheck cannot probe.
            cat <<'EOF'
      console:
        condition: service_healthy
    volumes:
      - tls-certs:/certs:ro
    healthcheck:
      disable: true
EOF
        fi
    done
}

write_override() {
    local need_override=0
    if [ "$OIDC_ENABLED" = 1 ]; then need_override=1; fi
    if [ "$PUBLIC_DNS_ENABLED" = 1 ]; then need_override=1; fi
    if [ "$PROXY_KIND" = traefik ]; then need_override=1; fi
    if [ "$NODE_COUNT" -gt 1 ]; then need_override=1; fi
    if [ "$LOCAL_IMAGE" = 1 ]; then need_override=1; fi
    if [ "$need_override" != 1 ]; then
        rm -f "$OUT_OVERRIDE"
        return
    fi

    {
        echo "# Deployment-specific adjustments layered over compose.yaml."
        echo "services:"
        # Patches are merged per service so each service key appears once.
        local svc body
        for svc in console server channel; do
            body=""
            # A locally built tag exists only on this host; never pull it.
            if [ "$LOCAL_IMAGE" = 1 ]; then
                body+=$'    pull_policy: never\n'
            fi
            if [ "$OIDC_ENABLED" = 1 ] && [ "$svc" != channel ]; then
                body+=$'    env_file:\n      - ./config/turnstone-oidc.env\n'
            fi
            if [ "$svc" = console ] && [ "$EXTERNAL_PROXY_ENABLED" = 1 ]; then
                body+="    networks:"$'\n'"      - turnstone-net"$'\n'"      - $PROXY_NETWORK"$'\n'
                body+="$(_traefik_console_labels "$PROXY_NETWORK")"$'\n'
            elif [ "$svc" = console ] && [ "$MANAGED_TRAEFIK" = 1 ]; then
                body+="$(_traefik_console_labels "${PROJECT_NAME}_turnstone-net")"$'\n'
            fi
            if [ -n "$body" ]; then
                printf '  %s:\n%s' "$svc" "$body"
            fi
        done
        if [ "$NODE_COUNT" -gt 1 ]; then
            write_extra_nodes
        fi
        if [ "$PUBLIC_DNS_ENABLED" = 1 ]; then
            # pull_policy: build — the image only exists locally (built from
            # ./caddy). Without it, `docker compose up` first tries to pull
            # the tag from a registry and prints a confusing
            # "pull access denied for turnstone-caddy" error.
            cat <<'EOF'
  caddy:
    build: ./caddy
    image: turnstone-caddy:dns
    pull_policy: build
    ports:
      - "80:80"
EOF
            case "$DNS_PROVIDER" in
                cloudflare)
                    printf '    environment:\n      CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}\n' ;;
                route53)
                    printf '    environment:\n      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}\n      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}\n' ;;
                duckdns)
                    printf '    environment:\n      DUCKDNS_API_TOKEN: ${DUCKDNS_API_TOKEN}\n' ;;
            esac
        fi
        if [ "$PROXY_KIND" = traefik ]; then
            # An unused profile keeps caddy defined but never started, and
            # !reset drops its published port so it cannot clash with Traefik.
            cat <<'EOF'
  caddy:
    profiles: ["disabled"]
    ports: !reset null
EOF
        fi
        if [ "$MANAGED_TRAEFIK" = 1 ]; then
            _traefik_service_block
        fi
        if [ "$EXTERNAL_PROXY_ENABLED" = 1 ] || { [ "$MANAGED_TRAEFIK" = 1 ] && [ -n "$PROXY_NETWORK" ]; }; then
            printf 'networks:\n  %s:\n    external: true\n' "$PROXY_NETWORK"
        fi
    } >"$OUT_OVERRIDE"
}

write_env_file() {
    # Compose auto-loads compose.override.yaml, but only while COMPOSE_FILE is
    # unset — so the variable is written for the mTLS chain only, and must then
    # name the override explicitly.
    local compose_chain=""
    if [ "$MTLS_ENABLED" = 1 ]; then
        compose_chain="compose.yaml"
        if [ -f "$OUT_OVERRIDE" ]; then compose_chain="$compose_chain:compose.override.yaml"; fi
        compose_chain="$compose_chain:tls.compose.yaml"
    fi

    info "Generating secrets and writing $OUT_ENV"
    local jwt_secret pg_password existing_jwt="" existing_pg=""

    # Preserve existing secrets from a prior .env so a rerun does not
    # regenerate them and break an existing Postgres data volume.
    if [ -f "$OUT_ENV" ]; then
        existing_jwt="$(grep -m1 '^TURNSTONE_JWT_SECRET=' "$OUT_ENV" | cut -d= -f2-)" || true
        existing_pg="$(grep -m1 '^POSTGRES_PASSWORD=' "$OUT_ENV" | cut -d= -f2-)" || true
    fi

    jwt_secret="${TURNSTONE_JWT_SECRET:-${existing_jwt:-$(gen_hex)}}"

    # Resolve POSTGRES_PASSWORD. When a fresh random value would be generated
    # (no exported variable and no existing .env value), check for a stale
    # Docker named volume that was initialised with a different password —
    # Postgres only applies POSTGRES_PASSWORD on first data-directory init.
    local _pg_source=""
    if [ -n "${POSTGRES_PASSWORD:-}" ]; then
        pg_password="$POSTGRES_PASSWORD"
        _pg_source="env"
    elif [ -n "${_FILE_DEFAULTS[POSTGRES_PASSWORD]:-}" ]; then
        pg_password="${_FILE_DEFAULTS[POSTGRES_PASSWORD]}"
        _ANSWERS[POSTGRES_PASSWORD]="$pg_password"
        _pg_source="file"
    elif [ -n "$existing_pg" ]; then
        pg_password="$existing_pg"
        _pg_source="existing"
    else
        local _pg_vol="${PROJECT_NAME}_postgres-data"
        local _vol_inspect_out
        if _vol_inspect_out="$(docker volume inspect "$_pg_vol" 2>&1)"; then
            # Volume exists — a freshly generated password would not match the
            # one used when the volume was initialised, breaking auth.
            if _no_tty; then
                die "Postgres data volume '$_pg_vol' already exists but no POSTGRES_PASSWORD is \
available. A newly-generated password will not match the one used when the volume \
was initialised, causing 'FATAL: password authentication failed for user \"turnstone\"'. \
Remedies — choose one and rerun: \
(1) export POSTGRES_PASSWORD=<existing-password> before running the script, \
(2) add POSTGRES_PASSWORD=<existing-password> to $OUT_ANSWERS, or \
(3) remove the stale volume first (destroys all data): docker volume rm $_pg_vol"
            else
                warn "Postgres data volume '$_pg_vol' already exists."
                {
                    printf '\n'
                    printf '  Generating a fresh random POSTGRES_PASSWORD would not match the\n'
                    printf '  password used to initialise the existing data directory, causing:\n'
                    printf '    FATAL: password authentication failed for user "turnstone"\n'
                    printf '\n'
                    printf '  How to proceed:\n'
                    printf '    enter  — supply the existing POSTGRES_PASSWORD to reuse this volume\n'
                    printf '    wipe   — remove the volume and all its data, generate a new password\n'
                    printf '    abort  — exit; handle this manually\n'
                    printf '\n'
                } >/dev/tty
                local _pg_action
                prompt_choice _pg_action POSTGRES_VOLUME_ACTION \
                    "Action for existing volume '$_pg_vol'" enter \
                    enter wipe abort
                case "$_pg_action" in
                    enter)
                        prompt_value pg_password POSTGRES_PASSWORD \
                            "Existing POSTGRES_PASSWORD (will be stored in $OUT_ENV)"
                        _pg_source="entered"
                        ;;
                    wipe)
                        warn "Volume '$_pg_vol' and ALL its data will be permanently deleted."
                        if ! ask "Confirm deletion of volume '$_pg_vol'?" "" n; then
                            die "Deletion not confirmed. Aborting."
                        fi
                        docker volume rm "$_pg_vol" \
                            || die "Could not remove '$_pg_vol'. Steps to resolve: (1) run 'docker compose down' to stop any containers using the volume, (2) verify Docker daemon permissions, (3) rerun this script."
                        info "Volume '$_pg_vol' removed. A fresh password will be generated."
                        pg_password="$(gen_hex)"
                        _pg_source="generated"
                        ;;
                    abort)
                        die "Aborting. To proceed manually: (1) export POSTGRES_PASSWORD=<existing-password> and rerun, or (2) docker volume rm $_pg_vol to start fresh."
                        ;;
                esac
            fi
        else
            # Distinguish "volume not found" from a real Docker error.
            if echo "$_vol_inspect_out" | grep -qi "no such volume\|not found"; then
                pg_password="$(gen_hex)"
                _pg_source="generated"
            else
                # Unexpected Docker error; warn and proceed with a fresh
                # password. If a stale volume exists this may still cause an
                # auth failure, but the user will see the docker error output.
                warn "Could not query Docker volume '$_pg_vol': $_vol_inspect_out"
                warn "Proceeding with a fresh random password. If '$_pg_vol' exists with a different password, 'docker compose up -d' may fail with an auth error — rerun this script and supply POSTGRES_PASSWORD."
                pg_password="$(gen_hex)"
                _pg_source="generated"
            fi
        fi
    fi

    if [ -n "${TURNSTONE_JWT_SECRET:-}" ]; then
        info "TURNSTONE_JWT_SECRET: using exported environment variable"
    elif [ -n "$existing_jwt" ]; then
        warn "TURNSTONE_JWT_SECRET: preserving existing value from $OUT_ENV (not regenerated)"
    else
        info "TURNSTONE_JWT_SECRET: generated new random value"
    fi
    case "$_pg_source" in
        env)      info "POSTGRES_PASSWORD: using exported environment variable" ;;
        file)     info "POSTGRES_PASSWORD: using value from $OUT_ANSWERS" ;;
        existing) warn "POSTGRES_PASSWORD: preserving existing value from $OUT_ENV (not regenerated)" ;;
        entered)  info "POSTGRES_PASSWORD: using entered existing password (volume reused)" ;;
        *)        info "POSTGRES_PASSWORD: generated new random value" ;;
    esac

    {
        echo "# Generated deployment settings. Keep this file private (contains secrets)."
        echo "COMPOSE_PROJECT_NAME=$PROJECT_NAME"
        if [ -n "$compose_chain" ]; then
            echo "COMPOSE_FILE=$compose_chain"
        fi
        echo "TURNSTONE_IMAGE_TAG=$IMAGE_TAG"
        echo "TURNSTONE_JWT_SECRET=$jwt_secret"
        echo "POSTGRES_PASSWORD=$pg_password"
        echo "WORKSPACE_MOUNT=$WORKSPACE_DIR"
        if [ "$PUBLIC_DNS_ENABLED" = 1 ]; then
            # Publishes caddy on the standard HTTPS port (base maps $CONSOLE_HTTPS_PORT:443).
            echo "CONSOLE_HTTPS_PORT=443"
        fi
        if [ "$PUBLIC_DNS_ENABLED" = 1 ] || [ "$MANAGED_TRAEFIK" = 1 ]; then
            case "$DNS_PROVIDER" in
                cloudflare) echo "CF_DNS_API_TOKEN=$CF_TOKEN" ;;
                route53)
                    echo "AWS_ACCESS_KEY_ID=$AWS_KEY_ID"
                    echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET"
                    ;;
                duckdns)
                    echo "DUCKDNS_API_TOKEN=$DUCKDNS_TOKEN_VAL"
                    echo "DUCKDNS_TOKEN=$DUCKDNS_TOKEN_VAL"
                    ;;
            esac
        fi
        if [ "$LLM_ENABLED" = 1 ]; then
            echo "LLM_BASE_URL=$LLM_BASE_URL_VAL"
            echo "OPENAI_API_KEY=$LLM_API_KEY"
            if [ -n "$LLM_MODEL" ]; then echo "MODEL=$LLM_MODEL"; fi
        fi
        if [ "$CHANNELS_ENABLED" = 1 ]; then
            if [ -n "$DISCORD_TOKEN" ]; then
                echo "TURNSTONE_DISCORD_TOKEN=$DISCORD_TOKEN"
                echo "TURNSTONE_DISCORD_GUILD=$DISCORD_GUILD"
            fi
            if [ -n "$SLACK_TOKEN" ]; then echo "TURNSTONE_SLACK_TOKEN=$SLACK_TOKEN"; fi
            if [ -n "$SLACK_APP_TOKEN" ]; then echo "TURNSTONE_SLACK_APP_TOKEN=$SLACK_APP_TOKEN"; fi
        fi
    } >"$OUT_ENV"
    chmod 600 "$OUT_ENV"
}

print_done() {
    info "Setup complete. Deployment files are in: $SCRIPT_DIR"
    echo
    echo "Workspace mounted at /workspace in every server node: $WORKSPACE_DIR"
    echo
    echo "Start the stack:"
    echo "  cd $SCRIPT_DIR"
    echo "  docker compose up -d"
    echo
    if [ "$MANAGED_TRAEFIK" = 1 ]; then
        echo "Dashboard: https://$DOMAIN (Traefik in this stack owns ports 80/443;"
        echo "the DNS record for $DOMAIN must point at this host)."
        if [ "$TRAEFIK_DASHBOARD" = 1 ]; then
            echo "Traefik web UI: https://$TRAEFIK_DASHBOARD_HOST (behind forward auth)"
        fi
    elif [ "$EXTERNAL_PROXY_ENABLED" = 1 ]; then
        echo "Dashboard: https://$DOMAIN (served by the external Traefik on the"
        echo "'$PROXY_NETWORK' network; this stack publishes no ports itself)."
    elif [ "$PUBLIC_DNS_ENABLED" = 1 ]; then
        echo "Dashboard: https://$DOMAIN (ports 80/443 must be reachable and the"
        echo "DNS record for $DOMAIN must point at this host)."
    else
        echo "Dashboard: https://localhost:8443 (Caddy local CA — trust its root once:"
        echo "  docker compose exec caddy cat /data/caddy/pki/authorities/local/root.crt)"
    fi
    echo
    echo "First visit creates the local admin account. Connect an LLM backend in the"
    echo "console Models tab. See deployment.md for post-deploy steps."
}

main() {
    info "Turnstone deployment setup"
    echo

    # First action: make sure the repository ignores everything this script
    # generates, so a fork stays clean and can pull upstream without rebasing.
    ensure_gitignore_entries "${GITIGNORE_ENTRIES[@]}"

    # Load the persistent answers file before any prompts so that prior
    # answers serve as defaults and AUTORUN=true skips all interactive input.
    load_answers_file
    load_existing_secrets

    # Split point: a development stack needs none of the questions below.
    local mode
    prompt_choice mode TURNSTONE_SETUP_MODE \
        "Deploy a production environment or a development environment?" production production development
    if [ "$mode" = development ]; then
        info "Development selected — run ./run.sh from the repository root to start the dev stack."
        exit 0
    fi

    check_prereqs

    section_project_name

    # Required for any safe deployment: image provenance. Secrets are always
    # generated automatically, so answering 'no' everywhere below still
    # yields a secure stack (local-CA HTTPS, random credentials).
    section_image_source
    section_nodes
    section_workspace

    # Optional feature sections — each starts with a yes/no.
    section_oidc
    section_tls
    section_llm
    section_channels

    copy_stack_files
    write_caddyfile
    write_traefik_config
    write_oidc_env
    write_override
    write_env_file
    write_answers_file
    print_done
}

main "$@"
