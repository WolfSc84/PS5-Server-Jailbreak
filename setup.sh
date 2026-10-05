#!/usr/bin/env bash
# ==============================================================================
# PS5 Relapse-Exploit Host Setup & Container Runner
# Supported Runtimes: Docker & Podman (with or without Compose)
# Supported OS: Debian / Ubuntu, Fedora / RHEL, Arch Linux, openSUSE
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log_info()    { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[+]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[-]${NC} $1"; }

# ------------------------------------------------------------------------------
# 1. Root / Sudo Verification
# ------------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_warn "This script requires superuser privileges to configure firewall, start containers, and bind ports 53/80/443."
        log_info "Elevating with sudo..."
        exec sudo bash "$0" "$@"
    fi
}

# ------------------------------------------------------------------------------
# 2. Operating System Detection
# ------------------------------------------------------------------------------
detect_os() {
    if [ ! -f /etc/os-release ]; then
        log_error "Unable to detect OS: /etc/os-release not found."
        exit 1
    fi

    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-unknown}"

    log_info "Detected OS: ${BOLD}${PRETTY_NAME:-$OS_ID}${NC}"

    if [[ "$OS_ID" =~ ^(fedora|rhel|centos|almalinux|rocky)$ ]] || [[ "$OS_LIKE" =~ (fedora|rhel) ]]; then
        DISTRO_FAMILY="fedora"
    elif [[ "$OS_ID" =~ ^(debian|ubuntu|linuxmint|pop)$ ]] || [[ "$OS_LIKE" =~ (debian|ubuntu) ]]; then
        DISTRO_FAMILY="debian"
    elif [[ "$OS_ID" =~ ^(arch|manjaro|endeavouros)$ ]] || [[ "$OS_LIKE" =~ arch ]]; then
        DISTRO_FAMILY="arch"
    elif [[ "$OS_ID" =~ ^(opensuse|sles) ]] || [[ "$OS_LIKE" =~ (suse|opensuse) ]]; then
        DISTRO_FAMILY="suse"
    else
        log_warn "Unrecognized Linux distribution family ($OS_ID / $OS_LIKE)."
        DISTRO_FAMILY="generic"
    fi
}

# ------------------------------------------------------------------------------
# 3. Container Engine & Compose Detection
# ------------------------------------------------------------------------------
detect_container_engine() {
    # Check CLI flags
    for arg in "$@"; do
        case "$arg" in
            --docker) CONTAINER_ENGINE="docker" ;;
            --podman) CONTAINER_ENGINE="podman" ;;
        esac
    done

    # Check environment override
    if [ -n "$CONTAINER_ENGINE" ]; then
        log_info "Using container engine override: ${BOLD}${CONTAINER_ENGINE}${NC}"
    else
        # 1. Check if Docker is installed and active
        if command -v docker &>/dev/null; then
            if docker info &>/dev/null || systemctl is-active --quiet docker 2>/dev/null; then
                CONTAINER_ENGINE="docker"
                log_info "Detected active Docker engine."
            fi
        fi

        # 2. Check if Podman is installed (if docker wasn't detected as active)
        if [ -z "$CONTAINER_ENGINE" ] && command -v podman &>/dev/null; then
            CONTAINER_ENGINE="podman"
            log_info "Detected Podman engine."
        fi

        # 3. Docker installed but daemon stopped
        if [ -z "$CONTAINER_ENGINE" ] && command -v docker &>/dev/null; then
            CONTAINER_ENGINE="docker"
            log_info "Detected Docker installation."
        fi

        # 4. Fallback default if neither is installed
        if [ -z "$CONTAINER_ENGINE" ]; then
            case "$DISTRO_FAMILY" in
                fedora) CONTAINER_ENGINE="podman" ;;
                *)      CONTAINER_ENGINE="docker" ;;
            esac
            log_info "No container engine currently installed. Will install: ${BOLD}${CONTAINER_ENGINE}${NC}"
        fi
    fi

    detect_compose_cmd
}

detect_compose_cmd() {
    COMPOSE_CMD=""
    if [ "$CONTAINER_ENGINE" = "docker" ]; then
        if docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker compose"
        elif command -v docker-compose &>/dev/null; then
            COMPOSE_CMD="docker-compose"
        fi
    elif [ "$CONTAINER_ENGINE" = "podman" ]; then
        if command -v podman-compose &>/dev/null; then
            COMPOSE_CMD="podman-compose"
        elif podman compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="podman compose"
        fi
    fi

    if [ -n "$COMPOSE_CMD" ]; then
        log_success "Found Compose tool: ${BOLD}${COMPOSE_CMD}${NC}"
    else
        log_info "No Compose tool detected for ${CONTAINER_ENGINE}. Will fall back to direct '${CONTAINER_ENGINE} run'."
    fi
}

# ------------------------------------------------------------------------------
# 4. Dependency Installation (Only pending/missing packages)
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Checking host dependencies for container engine: ${BOLD}${CONTAINER_ENGINE}${NC}..."

    local NEED_CURL=false
    local NEED_IPROUTE=false
    local NEED_ENGINE=false
    local NEED_COMPOSE=false

    command -v curl &>/dev/null || NEED_CURL=true
    command -v ip &>/dev/null || NEED_IPROUTE=true
    command -v "$CONTAINER_ENGINE" &>/dev/null || NEED_ENGINE=true

    if [ -z "$COMPOSE_CMD" ]; then
        NEED_COMPOSE=true
    fi

    # If engine, curl, and iproute are already present, we don't strictly require compose
    if [ "$NEED_CURL" = false ] && [ "$NEED_IPROUTE" = false ] && [ "$NEED_ENGINE" = false ]; then
        if [ -n "$COMPOSE_CMD" ]; then
            log_success "All required dependencies (${CONTAINER_ENGINE}, ${COMPOSE_CMD}, curl, iproute2) are already installed."
            return
        else
            log_info "Basic dependencies are satisfied. Checking if compose can be installed (optional)..."
        fi
    fi

    case "$DISTRO_FAMILY" in
        fedora)
            local PKGS=()
            [ "$NEED_CURL" = true ] && PKGS+=("curl")
            [ "$NEED_IPROUTE" = true ] && PKGS+=("iproute")
            if [ "$CONTAINER_ENGINE" = "docker" ]; then
                [ "$NEED_ENGINE" = true ] && PKGS+=("moby-engine")
                [ "$NEED_COMPOSE" = true ] && PKGS+=("docker-compose")
            else
                [ "$NEED_ENGINE" = true ] && PKGS+=("podman")
                [ "$NEED_COMPOSE" = true ] && PKGS+=("podman-compose")
            fi
            if [ ${#PKGS[@]} -gt 0 ]; then
                dnf install -y "${PKGS[@]}" || true
            fi
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            local PKGS=()
            [ "$NEED_CURL" = true ] && PKGS+=("curl")
            [ "$NEED_IPROUTE" = true ] && PKGS+=("iproute2")
            if [ "$CONTAINER_ENGINE" = "docker" ]; then
                [ "$NEED_ENGINE" = true ] && PKGS+=("docker.io")
                [ "$NEED_COMPOSE" = true ] && PKGS+=("docker-compose-v2" "docker-compose-plugin" "docker-compose")
            else
                [ "$NEED_ENGINE" = true ] && PKGS+=("podman")
                [ "$NEED_COMPOSE" = true ] && PKGS+=("podman-compose")
            fi
            if [ ${#PKGS[@]} -gt 0 ]; then
                apt-get update -y || true
                for pkg in "${PKGS[@]}"; do
                    apt-get install -y "$pkg" 2>/dev/null || true
                done
            fi
            ;;
        arch)
            local PKGS=()
            [ "$NEED_CURL" = true ] && PKGS+=("curl")
            [ "$NEED_IPROUTE" = true ] && PKGS+=("iproute2")
            if [ "$CONTAINER_ENGINE" = "docker" ]; then
                [ "$NEED_ENGINE" = true ] && PKGS+=("docker" "docker-compose")
            else
                [ "$NEED_ENGINE" = true ] && PKGS+=("podman" "podman-compose")
            fi
            if [ ${#PKGS[@]} -gt 0 ]; then
                pacman -Sy --noconfirm --needed "${PKGS[@]}" || true
            fi
            ;;
        suse)
            local PKGS=()
            [ "$NEED_CURL" = true ] && PKGS+=("curl")
            [ "$NEED_IPROUTE" = true ] && PKGS+=("iproute2")
            if [ "$CONTAINER_ENGINE" = "docker" ]; then
                [ "$NEED_ENGINE" = true ] && PKGS+=("docker" "docker-compose")
            else
                [ "$NEED_ENGINE" = true ] && PKGS+=("podman" "podman-compose")
            fi
            if [ ${#PKGS[@]} -gt 0 ]; then
                zypper install -y "${PKGS[@]}" || true
            fi
            ;;
        generic)
            log_warn "Please ensure '$CONTAINER_ENGINE' and 'curl' are installed manually."
            ;;
    esac

    # Ensure docker service is running if using Docker
    if [ "$CONTAINER_ENGINE" = "docker" ] && command -v systemctl &>/dev/null; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    # Verify container engine is available
    if ! command -v "$CONTAINER_ENGINE" &>/dev/null; then
        log_error "Container engine '$CONTAINER_ENGINE' is not available in PATH."
        exit 1
    fi

    # Refresh compose detection after package checks
    detect_compose_cmd
    log_success "Container engine $($CONTAINER_ENGINE --version | head -n1) is ready."
}

# ------------------------------------------------------------------------------
# 5. Resolve Port 53 Conflicts (Disable dnsmasq / bind9)
# ------------------------------------------------------------------------------
configure_dns_services() {
    log_info "Ensuring host DNS services do not conflict with container port 53..."

    for svc in dnsmasq named bind9; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_warn "Active $svc detected. Stopping and disabling to release port 53 for the container..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_success "$svc stopped and disabled."
        fi
    done

    # Allow unprivileged rootless port binding from port 53 upwards
    sysctl -w net.ipv4.ip_unprivileged_port_start=53 >/dev/null 2>&1 || true
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.ip_unprivileged_port_start = 53" > /etc/sysctl.d/99-custom-ports.conf 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 6. Configure Host Firewall (Allow 80, 443, 53 UDP/TCP)
# ------------------------------------------------------------------------------
configure_firewall() {
    log_info "Configuring host firewall for ports 80 (HTTP), 443 (HTTPS), and 53 (DNS)..."

    # firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --add-service=dns --add-service=http --add-service=https --permanent >/dev/null 2>&1 || true
        firewall-cmd --add-port=53/udp --add-port=53/tcp --add-port=80/tcp --add-port=443/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_success "firewalld rules applied."

    # ufw
    elif command -v ufw &>/dev/null && ufw status | grep -qw "active"; then
        log_info "Configuring UFW (Uncomplicated Firewall)..."
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        ufw allow 53/udp >/dev/null
        ufw allow 53/tcp >/dev/null
        ufw reload >/dev/null 2>&1 || true
        log_success "UFW rules applied."

    # iptables fallback check
    elif command -v iptables &>/dev/null; then
        log_info "Checking iptables (ensure incoming traffic to 80, 443, 53 is permitted in INPUT chain)."
    else
        log_warn "No recognized active firewall daemon (firewalld/ufw). Assuming ports are unblocked."
    fi
}

# ------------------------------------------------------------------------------
# 7. Detect Host LAN IP & Configure .env
# ------------------------------------------------------------------------------
configure_env() {
    log_info "Detecting host LAN IP address..."

    # Detect the IP assigned to the primary route
    DETECTED_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    
    # Fallback to hostname -I if route lookup returned nothing
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP="127.0.0.1"
        log_warn "Could not automatically determine primary LAN IP. Defaulting to $DETECTED_IP."
    else
        log_success "Detected LAN IP: ${BOLD}${CYAN}${DETECTED_IP}${NC}"
    fi

    # Write or update .env
    log_info "Updating .env configuration with SERVER_IP=${DETECTED_IP}..."
    cat <<EOF > .env
# Auto-generated by setup.sh on $(date)
# Set the LAN IP address of your host machine for PS5 DNS redirection and browser loading
SERVER_IP=${DETECTED_IP}
EOF
    log_success ".env file configured successfully."
}

# ------------------------------------------------------------------------------
# 8. Build and Run Container (Compose or Native Run)
# ------------------------------------------------------------------------------
run_container() {
    log_info "Building and launching Relapse-Exploit container with ${BOLD}${CONTAINER_ENGINE}${NC}..."

    # Prepare Podman socket if needed for compatibility
    if [ "$CONTAINER_ENGINE" = "podman" ]; then
        if command -v systemctl &>/dev/null; then
            systemctl enable --now podman.socket >/dev/null 2>&1 || true
            if [ ! -e /var/run/docker.sock ] && [ -e /run/podman/podman.sock ]; then
                ln -sf /run/podman/podman.sock /var/run/docker.sock 2>/dev/null || true
            fi
        fi
        export DOCKER_HOST="${DOCKER_HOST:-unix:///run/podman/podman.sock}"
        export PODMAN_COMPOSE_PROVIDER="${PODMAN_COMPOSE_PROVIDER:-/usr/bin/podman-compose}"
    fi

    # Ensure payloads directory exists on host
    mkdir -p "${SCRIPT_DIR}/payloads"

    # Stop and clean up any previous instance
    if [ -n "$COMPOSE_CMD" ]; then
        $COMPOSE_CMD -f compose.yaml down 2>/dev/null || true
    fi
    $CONTAINER_ENGINE rm -f relapse-exploit 2>/dev/null || true

    # Launch with build
    COMPOSE_SUCCESS=false
    if [ -n "$COMPOSE_CMD" ]; then
        log_info "Attempting deployment using '${COMPOSE_CMD}'..."
        if $COMPOSE_CMD -f compose.yaml up -d --build; then
            COMPOSE_SUCCESS=true
        else
            log_warn "Compose invocation failed; attempting direct '${CONTAINER_ENGINE} run'..."
        fi
    fi

    if [ "$COMPOSE_SUCCESS" = false ]; then
        log_info "Building image with native '${CONTAINER_ENGINE} build'..."
        $CONTAINER_ENGINE build -t relapse-exploit:latest -f Containerfile .
        
        log_info "Starting container with native '${CONTAINER_ENGINE} run'..."
        local VOL_FLAG=""
        if [ "$CONTAINER_ENGINE" = "podman" ]; then
            VOL_FLAG=":Z"
        fi

        $CONTAINER_ENGINE run -d --name relapse-exploit \
            --restart unless-stopped \
            -p 80:80/tcp \
            -p 443:443/tcp \
            -p "${DETECTED_IP}:53:53/udp" \
            -v "${SCRIPT_DIR}/payloads:/app/payloads${VOL_FLAG}" \
            -e SERVER_IP="${DETECTED_IP}" \
            -e PYTHONUNBUFFERED=1 \
            relapse-exploit:latest
    fi

    log_success "Container started."
}

# ------------------------------------------------------------------------------
# 9. Health Check & Validation
# ------------------------------------------------------------------------------
verify_execution() {
    log_info "Verifying container health and HTTP server response..."

    MAX_RETRIES=15
    RETRY_COUNT=0
    SERVER_READY=false

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
        
        # Test HTTP response on localhost:80
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80/api/info 2>/dev/null || true)
        if [ "$HTTP_CODE" = "200" ]; then
            SERVER_READY=true
            break
        fi
        echo -n "."
    done
    echo ""

    if [ "$SERVER_READY" = true ]; then
        log_success "Relapse-Exploit is ONLINE and responding at http://${DETECTED_IP}:80/"
        
        local LOG_CMD
        local STOP_CMD
        if [ -n "$COMPOSE_CMD" ]; then
            LOG_CMD="sudo $COMPOSE_CMD logs -f"
            STOP_CMD="sudo $COMPOSE_CMD down"
        else
            LOG_CMD="sudo $CONTAINER_ENGINE logs -f relapse-exploit"
            STOP_CMD="sudo $CONTAINER_ENGINE rm -f relapse-exploit"
        fi

        echo ""
        echo -e "${BOLD}${GREEN}================================================================${NC}"
        echo -e "${BOLD}${GREEN}        PS5 RELAPSE EXPLOIT SERVER READY & OPERATIONAL         ${NC}"
        echo -e "${BOLD}${GREEN}================================================================${NC}"
        echo -e " Engine:             ${BOLD}${CYAN}${CONTAINER_ENGINE}${NC} ($([ -n "$COMPOSE_CMD" ] && echo "$COMPOSE_CMD" || echo "Direct run"))"
        echo -e " Host IP:            ${BOLD}${CYAN}http://${DETECTED_IP}/${NC}"
        echo -e " Payloads Volume:    ${BOLD}${YELLOW}${SCRIPT_DIR}/payloads${NC}"
        echo -e " Container Status:   ${BOLD}${GREEN}Active & Healthy${NC}"
        echo ""
        echo -e "${BOLD}Connection Instructions for PlayStation 5:${NC}"
        echo -e "  ${BOLD}Option 1 (User's Guide Method - Recommended):${NC}"
        echo -e "    1. On PS5, open Settings -> Network -> Settings -> Set Up Internet Connection."
        echo -e "    2. Set Primary DNS to: ${BOLD}${CYAN}${DETECTED_IP}${NC}"
        echo -e "    3. Go to Settings -> User's Guide, Health & Safety -> User's Guide."
        echo -e "    4. Accept the self-signed SSL certificate prompt."
        echo ""
        echo -e "  ${BOLD}Option 2 (Direct Browser / Messages Method):${NC}"
        echo -e "    1. Send a PSN message to any account containing: ${BOLD}${CYAN}http://${DETECTED_IP}/${NC}"
        echo -e "    2. Click the link in the message to load the exploit."
        echo ""
        echo -e " Useful Commands:"
        echo -e "  - View live logs:      ${BOLD}${LOG_CMD}${NC}"
        echo -e "  - Stop container:      ${BOLD}${STOP_CMD}${NC}"
        echo -e "  - Add payloads:        Drop .elf or .bin files directly into ${BOLD}./payloads/${NC}"
        echo -e "${BOLD}${GREEN}================================================================${NC}"
    else
        log_error "Server did not respond with HTTP 200 within timeout."
        log_warn "Printing recent container logs for diagnosis:"
        $CONTAINER_ENGINE logs relapse-exploit 2>&1 | tail -n 20 || true
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Main Flow
# ------------------------------------------------------------------------------
main() {
    echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
    echo -e "${BOLD}${CYAN}       PS5 Relapse-Exploit Setup & Container Deployment     ${NC}"
    echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
    check_root "$@"
    detect_os
    detect_container_engine "$@"
    install_dependencies
    configure_dns_services
    configure_firewall
    configure_env
    run_container
    verify_execution
}

main "$@"
