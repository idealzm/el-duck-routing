#!/usr/bin/env bash
set -e

# PasarGuard Panel installer with HAPP routing mod
# Usage: sudo bash install-happ.sh [OPTIONS]
#
# Options:
#   --image TAG     Docker image tag (default: happ-routing-v1)
#   --no-ssl       Skip SSL setup
#   --ssl-domain D  Use Let's Encrypt for domain D
#   --database TYPE  Database type: sqlite (default), mysql, mariadb, postgresql, timescaledb

IMAGE_REGISTRY="ghcr.io"
IMAGE_REPO="idealzm/el-duck-routing"
IMAGE_TAG=""

INSTALL_DIR="/opt"
APP_NAME="pasarguard"
APP_DIR="${INSTALL_DIR}/${APP_NAME}"
DATA_DIR="/var/lib/${APP_NAME}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
PASARGUARD_SCRIPT_URL="https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

colorized_echo() {
    local color="$1"
    shift
    printf "${color}%s${NC}\n" "$@"
}

check_running_as_root() {
    if [ "$(id -u)" -ne 0 ]; then
        colorized_echo "$RED" "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_VERSION=""
    else
        OS_ID="unknown"
        OS_VERSION=""
    fi
    colorized_echo "$BLUE" "Detected OS: ${OS_ID} ${OS_VERSION}"
}

install_package() {
    local package="$1"
    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -qq && apt-get install -y -qq "$package" >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y "$package" >/dev/null 2>&1 || dnf install -y "$package" >/dev/null 2>&1
            ;;
        *)
            colorized_echo "$RED" "Unsupported OS for package installation: $OS_ID"
            exit 1
            ;;
    esac
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi
    colorized_echo "$BLUE" "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
    colorized_echo "$GREEN" "Docker installed"
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    else
        colorized_echo "$RED" "Neither docker compose nor docker-compose found"
        exit 1
    fi
}

install_yq() {
    if command -v yq >/dev/null 2>&1; then
        return 0
    fi
    colorized_echo "$BLUE" "Installing yq..."
    local yq_version="v4.45.1"
    local yq_binary="yq_linux_amd64"
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${yq_version}/${yq_binary}" -o /usr/bin/yq
    chmod +x /usr/bin/yq
}

login_ghcr() {
    colorized_echo "$CYAN" "GitHub Container Registry login required."
    colorized_echo "$CYAN" "You need a GitHub Personal Access Token with 'read:packages' scope."
    colorized_echo "$CYAN" "Create one at: https://github.com/settings/tokens/new?scopes=read:packages"
    echo ""
    read -p "GitHub username: " GHCR_USER
    read -p "GitHub token (read:packages): " GHCR_TOKEN
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
    if [ $? -ne 0 ]; then
        colorized_echo "$RED" "Failed to login to GHCR"
        exit 1
    fi
    colorized_echo "$GREEN" "Logged in to GHCR"
}

install_command() {
    check_running_as_root

    local database_type="sqlite"
    local ssl_mode="auto"
    local ssl_domain=""

    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
        --image)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --database)
            database_type="$2"
            shift 2
            ;;
        --no-ssl)
            ssl_mode="disabled"
            shift
            ;;
        --ssl-domain)
            ssl_domain="$2"
            ssl_mode="domain"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
        esac
    done

    detect_os
    install_docker
    detect_compose
    install_yq

    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi

    # Login to GHCR first
    login_ghcr

    # Determine image tag
    if [ -z "$IMAGE_TAG" ]; then
        colorized_echo "$BLUE" "Fetching latest image tag..."
        IMAGE_TAG=$(curl -s "https://ghcr.io/v2/${IMAGE_REPO}/tags/list" 2>/dev/null | jq -r '.tags[-1] // "happ-routing-v1"')
        if [ -z "$IMAGE_TAG" ] || [ "$IMAGE_TAG" = "null" ]; then
            IMAGE_TAG="happ-routing-v1"
        fi
    fi

    local FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$GREEN" "  PasarGuard Panel + HAPP Routing Mod"
    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$CYAN" "Image: ${FULL_IMAGE}"
    colorized_echo "$CYAN" "Database: ${database_type}"
    echo ""

    # Run official installer first (it handles everything)
    colorized_echo "$BLUE" "Running official PasarGuard installer..."
    bash -c "$(curl -fsSL ${PASARGUARD_SCRIPT_URL})" @ install --database "$database_type" --no-ssl

    # Replace the image in docker-compose.yml
    colorized_echo "$BLUE" "Switching to HAPP routing mod image..."
    yq -i ".services.pasarguard.image = \"${FULL_IMAGE}\"" "$COMPOSE_FILE"

    # Also check for 'panel' service name
    if yq -e '.services.panel' "$COMPOSE_FILE" >/dev/null 2>&1; then
        yq -i ".services.panel.image = \"${FULL_IMAGE}\"" "$COMPOSE_FILE"
    fi

    # Stop and restart with new image
    colorized_echo "$BLUE" "Pulling HAPP routing mod image..."
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" pull

    colorized_echo "$BLUE" "Restarting services..."
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d

    echo ""
    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$GREEN" "  HAPP Routing Mod Installed!"
    colorized_echo "$GREEN" "=============================================="
    colorized_echo "$CYAN" "Next steps:"
    colorized_echo "$CYAN" "  1. Open the panel in your browser"
    colorized_echo "$CYAN" "  2. Go to Settings → Subscriptions"
    colorized_echo "$CYAN" "  3. In the HAPP Routing field, paste the deeplink from:"
    colorized_echo "$CYAN" "     curl -sL https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/HAPP/DEFAULT.DEEPLINK"
    colorized_echo "$CYAN" "  4. Save settings"
    echo ""
    colorized_echo "$CYAN" "To update the HAPP routing config later, repeat step 3."
}

update_command() {
    check_running_as_root
    detect_compose

    if [ -z "$IMAGE_TAG" ]; then
        IMAGE_TAG="happ-routing-v1"
    fi

    local FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

    colorized_echo "$BLUE" "Pulling latest image: ${FULL_IMAGE}"
    docker pull "$FULL_IMAGE"

    # Update compose file
    yq -i ".services.pasarguard.image = \"${FULL_IMAGE}\"" "$COMPOSE_FILE"
    if yq -e '.services.panel' "$COMPOSE_FILE" >/dev/null 2>&1; then
        yq -i ".services.panel.image = \"${FULL_IMAGE}\"" "$COMPOSE_FILE"
    fi

    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" down
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" up -d

    colorized_echo "$GREEN" "Update complete!"
}

case "$1" in
    @)
        shift
        case "$2" in
            install)
                shift 2
                install_command "$@"
                ;;
            update)
                shift 2
                update_command "$@"
                ;;
            *)
                echo "Usage: $0 @ {install|update} [OPTIONS]"
                echo ""
                echo "Commands:"
                echo "  install  - Install PasarGuard with HAPP routing mod"
                echo "  update   - Update to latest HAPP routing mod image"
                echo ""
                echo "Install options:"
                echo "  --image TAG       Docker image tag (default: happ-routing-v1)"
                echo "  --database TYPE   Database: sqlite (default), mysql, mariadb, postgresql, timescaledb"
                echo "  --no-ssl          Skip SSL setup"
                echo "  --ssl-domain D    Use Let's Encrypt for domain D"
                echo ""
                echo "Update options:"
                echo "  --image TAG       Docker image tag to update to"
                exit 1
                ;;
        esac
        ;;
    install)
        shift
        install_command "$@"
        ;;
    update)
        shift
        update_command "$@"
        ;;
    *)
        echo "PasarGuard Panel + HAPP Routing Mod"
        echo ""
        echo "Usage: $0 {install|update} [OPTIONS]"
        echo ""
        echo "Commands:"
        echo "  install  - Install PasarGuard with HAPP routing mod"
        echo "  update   - Update to latest HAPP routing mod image"
        echo ""
        echo "Install options:"
        echo "  --image TAG       Docker image tag (default: happ-routing-v1)"
        echo "  --database TYPE   Database: sqlite (default), mysql, mariadb, postgresql, timescaledb"
        echo "  --no-ssl          Skip SSL setup"
        echo "  --ssl-domain D    Use Let's Encrypt for domain D"
        echo ""
        echo "Update options:"
        echo "  --image TAG       Docker image tag to update to"
        exit 1
        ;;
esac