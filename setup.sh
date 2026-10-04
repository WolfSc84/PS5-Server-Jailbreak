#!/usr/bin/env bash
# ==============================================================================
# PS5 Relapse-Exploit Host Setup & Container Runner
# Supported OS: Fedora / RHEL, Debian / Ubuntu, Arch Linux
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
        log_warn "This script requires superuser privileges to install packages, configure firewall, and bind ports 53/80/443."
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

    # Source os-release
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
    else
        log_warn "Unrecognized Linux distribution family ($OS_ID / $OS_LIKE)."
        log_warn "Attempting to continue using generic package fallback..."
        DISTRO_FAMILY="generic"
    fi
}

# ------------------------------------------------------------------------------
# 3. Dependency Installation
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Checking and installing required host dependencies (podman, podman-compose, curl)..."

    case "$DISTRO_FAMILY" in
        fedora)
            dnf install -y podman podman-compose firewalld curl iproute
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y podman curl iproute2
            # Try to install podman-compose via apt, fallback to pip3 if not packaged
            if ! apt-get install -y podman-compose; then
                log_info "podman-compose not available via apt; installing via python3-pip..."
                apt-get install -y python3-pip python3-setuptools
                pip3 install --break-system-packages podman-compose 2>/dev/null || pip3 install podman-compose
            fi
            ;;
        arch)
            pacman -Sy --noconfirm --needed podman podman-compose curl iproute2
            ;;
        generic)
            log_warn "Please ensure 'podman', 'podman-compose', and 'curl' are installed manually."
            ;;
    esac

    # Verify podman exists
    if ! command -v podman &>/dev/null; then
        log_error "Podman could not be installed or found in PATH."
        exit 1
    fi
    log_success "Podman $(podman --version | head -n1) is ready."
}

# ------------------------------------------------------------------------------
# 4. Resolve Port 53 Conflicts (Disable dnsmasq)
# ------------------------------------------------------------------------------
configure_dns_services() {
    log_info "Ensuring host DNS services do not conflict with container port 53..."

    # Check for dnsmasq
    if systemctl list-unit-files | grep -qw "dnsmasq.service"; then
        if systemctl is-active --quiet dnsmasq; then
            log_warn "Active dnsmasq detected. Stopping and disabling to release port 53 for the container..."
            systemctl stop dnsmasq
            systemctl disable dnsmasq
            log_success "dnsmasq stopped and disabled."
        fi
    fi

    # Allow unprivileged rootless port binding from port 53 upwards
    sysctl -w net.ipv4.ip_unprivileged_port_start=53 >/dev/null 2>&1 || true
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.ip_unprivileged_port_start = 53" > /etc/sysctl.d/99-podman-ports.conf 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 5. Configure Host Firewall (Allow 80, 443, 53 UDP/TCP)
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
# 6. Detect Host LAN IP & Configure .env
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
# 7. Build and Run Container with Podman Compose
# ------------------------------------------------------------------------------
run_container() {
    log_info "Building and launching Relapse-Exploit container via podman-compose..."

    # Determine compose command
    if command -v podman-compose &>/dev/null; then
        COMPOSE_CMD="podman-compose"
    elif podman compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="podman compose"
    else
        log_error "Neither 'podman-compose' nor 'podman compose' is available."
        exit 1
    fi

    # Ensure payloads directory exists on host
    mkdir -p ./payloads

    # Stop any previous instance
    $COMPOSE_CMD down 2>/dev/null || true

    # Launch with build
    $COMPOSE_CMD up -d --build

    log_success "Container started."
}

# ------------------------------------------------------------------------------
# 8. Health Check & Validation
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
        
        echo ""
        echo -e "${BOLD}${GREEN}================================================================${NC}"
        echo -e "${BOLD}${GREEN}        PS5 RELAPSE EXPLOIT SERVER READY & OPERATIONAL         ${NC}"
        echo -e "${BOLD}${GREEN}================================================================${NC}"
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
        echo -e "  - View live logs:      ${BOLD}sudo podman-compose logs -f${NC}"
        echo -e "  - Stop container:      ${BOLD}sudo podman-compose down${NC}"
        echo -e "  - Add payloads:        Drop .elf or .bin files directly into ${BOLD}./payloads/${NC}"
        echo -e "${BOLD}${GREEN}================================================================${NC}"
    else
        log_error "Server did not respond with HTTP 200 within timeout."
        log_warn "Printing recent container logs for diagnosis:"
        podman logs relapse-exploit 2>&1 | tail -n 20 || true
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
    install_dependencies
    configure_dns_services
    configure_firewall
    configure_env
    run_container
    verify_execution
}

main "$@"
