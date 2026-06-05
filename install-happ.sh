#!/usr/bin/env bash
set -e

# PasarGuard Panel + HAPP Routing Mod Installer
# Usage: sudo bash install-happ.sh [OPTIONS]
#
# Options:
#   --image TAG         Docker image tag (default: happ-routing-v1)
#   --database TYPE     Database: sqlite (default), mysql, mariadb, postgresql
#   --no-ssl           Skip SSL setup
#   --ssl-domain D     Use Let's Encrypt for domain D

IMAGE_REGISTRY="ghcr.io"
IMAGE_REPO="idealzm/el-duck-routing"
IMAGE_TAG=""
PASARGUARD_SCRIPT_URL="https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh"

INSTALL_DIR="/opt"
APP_NAME="pasarguard"
APP_DIR="${INSTALL_DIR}/${APP_NAME}"
DATA_DIR="/var/lib/${APP_NAME}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

colorized_echo() {
    local color="$1"; shift
    printf "${color}%s${NC}\n" "$@"
}

check_running_as_root() {
    [ "$(id -u)" -eq 0 ] || { colorized_echo "$RED" "Run as root"; exit 1; }
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    else
        colorized_echo "$RED" "docker compose not found"; exit 1
    fi
}

install_command() {
    check_running_as_root

    local database_type=""
    local extra_db_args=""

    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
        --image)     IMAGE_TAG="$2"; shift 2 ;;
        --database)  database_type="$2"; shift 2 ;;
        --no-ssl)    EXTRA_INSTALL_ARGS="--no-ssl"; shift ;;
        --ssl-domain) EXTRA_INSTALL_ARGS="--ssl-domain $2"; shift 2 ;;
        *)           shift ;;
        esac
    done

    # Login to GHCR
    colorized_echo "$CYAN" "GitHub Container Registry login required."
    colorized_echo "$CYAN" "Create a token at: https://github.com/settings/tokens/new?scopes=read:packages"
    echo ""
    read -p "GitHub username: " GHCR_USER
    read -p "GitHub token (read:packages): " GHCR_TOKEN
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin || {
        colorized_echo "$RED" "GHCR login failed"; exit 1
    }
    colorized_echo "$GREEN" "Logged in to GHCR"

    # Set default tag
    IMAGE_TAG="${IMAGE_TAG:-happ-routing-v1}"
    local FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$GREEN" "  PasarGuard Panel + HAPP Routing Mod"
    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$CYAN" "Image: ${FULL_IMAGE}"
    echo ""

    # Build official installer args
    INSTALL_CMD="bash -c \"\$(curl -fsSL ${PASARGUARD_SCRIPT_URL})\" @ install"
    if [ -n "$database_type" ]; then
        INSTALL_CMD="${INSTALL_CMD} --database ${database_type}"
    fi
    if [ -n "$EXTRA_INSTALL_ARGS" ]; then
        INSTALL_CMD="${INSTALL_CMD} ${EXTRA_INSTALL_ARGS}"
    fi

    colorized_echo "$BLUE" "Running official PasarGuard installer..."
    eval "$INSTALL_CMD"

    # Replace image in docker-compose.yml
    colorized_echo "$BLUE" "Switching to HAPP routing mod image: ${FULL_IMAGE}"
    detect_compose

    # Install yq if needed
    if ! command -v yq >/dev/null 2>&1; then
        colorized_echo "$BLUE" "Installing yq..."
        curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64" -o /usr/bin/yq
        chmod +x /usr/bin/yq
    fi

    # Replace all pasarguard/panel images
    for svc in $($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" config --services 2>/dev/null || echo "pasarguard"); do
        current_image=$(yq eval ".services.\"${svc}\".image // \"\"" "$COMPOSE_FILE" 2>/dev/null || true)
        if [[ "$current_image" =~ ^pasarguard/panel([:@].*)?$ ]]; then
            yq -i ".services.\"${svc}\".image = \"${FULL_IMAGE}\"" "$COMPOSE_FILE"
        fi
    done

    colorized_echo "$BLUE" "Pulling HAPP routing mod image..."
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" pull

    colorized_echo "$BLUE" "Restarting with new image..."
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d

    echo ""
    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$GREEN" "  HAPP Routing Mod Installed!"
    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$CYAN" "Next steps:"
    colorized_echo "$CYAN" "  1. Open the panel in your browser"
    colorized_echo "$CYAN" "  2. Go to Settings > Subscriptions"
    colorized_echo "$CYAN" "  3. In HAPP Routing field, paste the output of:"
    colorized_echo "$CYAN" "     curl -sL https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/HAPP/DEFAULT.DEEPLINK"
    colorized_echo "$CYAN" "  4. Save settings"
}

update_command() {
    check_running_as_root
    detect_compose

    IMAGE_TAG="${IMAGE_TAG:-happ-routing-v1}"
    local FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

    colorized_echo "$BLUE" "Pulling: ${FULL_IMAGE}"
    docker pull "$FULL_IMAGE"

    for svc in $($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" config --services 2>/dev/null || echo "pasarguard"); do
        current_image=$(yq eval ".services.\"${svc}\".image // \"\"" "$COMPOSE_FILE" 2>/dev/null || true)
        if [[ "$current_image" =~ ghcr\.io.*el-duck-routing ]] || [[ "$current_image" =~ ^pasarguard/panel ]]; then
            yq -i ".services.\"${svc}\".image = \"${FULL_IMAGE}\"" "$COMPOSE_FILE"
        fi
    done

    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d
    colorized_echo "$GREEN" "Updated!"
}

case "${1:-}" in
    install) shift; install_command "$@" ;;
    update)  shift; update_command "$@" ;;
    @)       shift; case "${1:-}" in
                 install) shift; install_command "$@" ;;
                 update)  shift; update_command "$@" ;;
                 *) echo "Usage: $0 @ {install|update} [OPTIONS]"; exit 1 ;;
             esac ;;
    *)       echo "PasarGuard Panel + HAPP Routing Mod"
             echo ""
             echo "Usage: $0 {install|update} [OPTIONS]"
             echo ""
             echo "  install  - Install with HAPP routing mod"
             echo "  update   - Update HAPP routing mod image"
             echo ""
             echo "Install options:"
             echo "  --image TAG       Image tag (default: happ-routing-v1)"
             echo "  --database TYPE   Database: mysql, mariadb, postgresql, timescaledb (default: sqlite)"
             echo "  --no-ssl          Skip SSL"
             echo "  --ssl-domain D    Let's Encrypt domain"
             exit 1 ;;
esac