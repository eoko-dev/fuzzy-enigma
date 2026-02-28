#!/usr/bin/env bash
# HoneyStack - Lightweight Modular Honeypot Platform
# Single-command installer
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/honeystack.conf"
ENV_FILE="${SCRIPT_DIR}/.env"
INSTALL_DIR="/opt/honeystack"
LOG_DIR="/var/log/honeypots"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[+]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1"; }
log_step()  { echo -e "${CYAN}[*]${NC} $1"; }

###############################################################################
# Pre-flight checks
###############################################################################
preflight_checks() {
    log_step "Running pre-flight checks..."

    # Root check
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # OS detection
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-unknown}"
        log_info "Detected OS: ${PRETTY_NAME:-$OS_ID}"
    else
        log_error "Cannot detect OS. Only Ubuntu/Debian are supported."
        exit 1
    fi

    case "${OS_ID}" in
        ubuntu|debian) ;;
        *)
            log_warn "Unsupported OS: ${OS_ID}. This script is designed for Ubuntu/Debian."
            log_warn "Continuing anyway — some features may not work."
            ;;
    esac

    # RAM check
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
    log_info "Available RAM: ${TOTAL_RAM_MB}MB"

    if [[ ${TOTAL_RAM_MB} -lt 512 ]]; then
        log_error "Minimum 512MB RAM required. Found ${TOTAL_RAM_MB}MB. Aborting."
        exit 1
    elif [[ ${TOTAL_RAM_MB} -lt 1024 ]]; then
        log_warn "Less than 1GB RAM detected. HoneyStack may run with reduced performance."
    fi

    # Check if already installed
    if [[ -f "${INSTALL_DIR}/.installed" ]]; then
        log_warn "HoneyStack appears to be already installed at ${INSTALL_DIR}"
        read -rp "Reinstall? This will stop existing containers. [y/N]: " confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            log_info "Aborted."
            exit 0
        fi
        log_step "Stopping existing deployment..."
        cd "${INSTALL_DIR}" && docker compose down 2>/dev/null || true
    fi

    log_info "Pre-flight checks passed."
}

###############################################################################
# Install Docker
###############################################################################
install_docker() {
    if command -v docker &>/dev/null; then
        DOCKER_VERSION=$(docker --version 2>/dev/null || echo "unknown")
        log_info "Docker already installed: ${DOCKER_VERSION}"

        # Verify docker compose plugin
        if docker compose version &>/dev/null; then
            log_info "Docker Compose plugin available."
            return 0
        else
            log_warn "Docker Compose plugin not found. Installing..."
        fi
    else
        log_step "Installing Docker..."
    fi

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release >/dev/null

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Add Docker repository
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
            $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" > /etc/apt/sources.list.d/docker.list
    fi

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null

    systemctl enable docker
    systemctl start docker

    log_info "Docker installed successfully."
}

###############################################################################
# Install iptables dependencies
###############################################################################
install_iptables() {
    if ! command -v iptables &>/dev/null; then
        log_step "Installing iptables..."
        apt-get install -y -qq iptables >/dev/null
    fi

    # Install iptables-persistent for rule persistence
    if ! dpkg -l iptables-persistent &>/dev/null 2>&1; then
        log_step "Installing iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y -qq iptables-persistent >/dev/null
    fi
}

###############################################################################
# Load configuration
###############################################################################
load_config() {
    log_step "Loading configuration..."

    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONF_FILE}"
    fi

    # Defaults
    ENABLED_HONEYPOTS="${ENABLED_HONEYPOTS:-cowrie}"
    SSH_PORT="${SSH_PORT:-22222}"
    GRAFANA_PORT="${GRAFANA_PORT:-3000}"
    INSTALL_DIR="${INSTALL_DIR:-/opt/honeystack}"
    LOG_DIR="${LOG_DIR:-/var/log/honeypots}"

    # Create .env from template if it doesn't exist
    if [[ ! -f "${ENV_FILE}" ]]; then
        if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
            cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}"
        else
            cat > "${ENV_FILE}" <<EOF
GRAFANA_ADMIN_PASSWORD=honeystack
GRAFANA_PORT=${GRAFANA_PORT}
SSH_PORT=${SSH_PORT}
COWRIE_SSH_PORT=2222
COWRIE_TELNET_PORT=2223
COWRIE_HOSTNAME=svr04
LOKI_RETENTION=168h
LOG_DIR=${LOG_DIR}
EOF
        fi
    fi

    # Source the env file
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a

    log_info "Enabled honeypots: ${ENABLED_HONEYPOTS}"
}

###############################################################################
# Reconfigure SSH
###############################################################################
reconfigure_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    local current_port

    # Detect current SSH port
    current_port=$(grep -E "^#?Port " "${sshd_config}" 2>/dev/null | tail -1 | awk '{print $2}')
    current_port="${current_port:-22}"

    if [[ "${current_port}" == "${SSH_PORT}" ]]; then
        log_info "SSH already configured on port ${SSH_PORT}."
        return 0
    fi

    log_step "Reconfiguring SSH from port ${current_port} to ${SSH_PORT}..."

    # Backup sshd_config
    cp "${sshd_config}" "${sshd_config}.honeystack.bak"
    log_info "Backed up sshd_config to ${sshd_config}.honeystack.bak"

    # Update port
    if grep -qE "^Port " "${sshd_config}"; then
        sed -i "s/^Port .*/Port ${SSH_PORT}/" "${sshd_config}"
    elif grep -qE "^#Port " "${sshd_config}"; then
        sed -i "s/^#Port .*/Port ${SSH_PORT}/" "${sshd_config}"
    else
        echo "Port ${SSH_PORT}" >> "${sshd_config}"
    fi

    # Restart SSH
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: SSH port is changing to ${SSH_PORT}                       ║${NC}"
    echo -e "${RED}║  Your current session will NOT be affected.                 ║${NC}"
    echo -e "${RED}║  For new connections use: ssh -p ${SSH_PORT} user@host              ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart ssh
    fi

    # Verify SSH is listening on new port
    sleep 2
    if ss -tlnp | grep -q ":${SSH_PORT}"; then
        log_info "SSH is now listening on port ${SSH_PORT}."
    else
        log_warn "Could not verify SSH on port ${SSH_PORT}. Check manually."
    fi
}

###############################################################################
# Set up iptables port redirection
###############################################################################
setup_iptables() {
    local cowrie_ssh_port="${COWRIE_SSH_PORT:-2222}"
    local cowrie_telnet_port="${COWRIE_TELNET_PORT:-2223}"

    log_step "Setting up iptables port redirection..."

    # Clean up any existing HoneyStack rules
    local existing_rules
    existing_rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "honeystack" || true)
    if [[ -n "${existing_rules}" ]]; then
        while read -r rule; do
            # shellcheck disable=SC2086
            iptables -t nat ${rule//-A/-D} 2>/dev/null || true
        done <<< "${existing_rules}"
    fi

    # Redirect port 22 → Cowrie SSH
    iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port "${cowrie_ssh_port}" \
        -m comment --comment "honeystack-ssh"
    log_info "Port 22 → ${cowrie_ssh_port} (Cowrie SSH)"

    # Redirect port 23 → Cowrie Telnet
    iptables -t nat -A PREROUTING -p tcp --dport 23 -j REDIRECT --to-port "${cowrie_telnet_port}" \
        -m comment --comment "honeystack-telnet"
    log_info "Port 23 → ${cowrie_telnet_port} (Cowrie Telnet)"

    # Persist iptables rules
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    log_info "iptables rules configured and persisted."
}

###############################################################################
# Create directory structure
###############################################################################
create_directories() {
    log_step "Creating directory structure..."

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${LOG_DIR}"

    # Create log directories for each enabled honeypot
    for honeypot in ${ENABLED_HONEYPOTS}; do
        mkdir -p "${LOG_DIR}/${honeypot}"
        chmod 777 "${LOG_DIR}/${honeypot}"
        log_info "Created log directory: ${LOG_DIR}/${honeypot}"
    done

    log_info "Directories created."
}

###############################################################################
# Copy project files to install directory
###############################################################################
copy_files() {
    log_step "Copying files to ${INSTALL_DIR}..."

    # Copy core infrastructure
    cp -r "${SCRIPT_DIR}/core" "${INSTALL_DIR}/"

    # Copy honeypot modules
    cp -r "${SCRIPT_DIR}/honeypots" "${INSTALL_DIR}/"

    # Copy env and config
    cp "${ENV_FILE}" "${INSTALL_DIR}/.env"
    cp "${CONF_FILE}" "${INSTALL_DIR}/honeystack.conf"

    # Copy Cowrie dashboard into Grafana dashboards directory
    for honeypot in ${ENABLED_HONEYPOTS}; do
        local dashboard="${INSTALL_DIR}/honeypots/${honeypot}/dashboard-${honeypot}.json"
        if [[ -f "${dashboard}" ]]; then
            cp "${dashboard}" "${INSTALL_DIR}/core/grafana/dashboards/"
            log_info "Installed dashboard for ${honeypot}"
        fi
    done

    log_info "Files copied."
}

###############################################################################
# Generate merged docker-compose.yml
###############################################################################
generate_compose() {
    log_step "Generating docker-compose.yml..."

    local compose_file="${INSTALL_DIR}/docker-compose.yml"
    local compose_files=("-f" "${INSTALL_DIR}/core/docker-compose.core.yml")

    # Add enabled honeypot compose files
    for honeypot in ${ENABLED_HONEYPOTS}; do
        local hp_compose="${INSTALL_DIR}/honeypots/${honeypot}/docker-compose.${honeypot}.yml"
        if [[ -f "${hp_compose}" ]]; then
            compose_files+=("-f" "${hp_compose}")
            log_info "Including honeypot module: ${honeypot}"
        else
            log_warn "Compose file not found for honeypot: ${honeypot} (skipping)"
        fi
    done

    # Generate the merged compose file
    cd "${INSTALL_DIR}"
    docker compose "${compose_files[@]}" config > "${compose_file}" 2>/dev/null

    log_info "Generated ${compose_file}"
}

###############################################################################
# Pull images and start containers
###############################################################################
start_services() {
    log_step "Pulling Docker images (this may take a few minutes)..."

    cd "${INSTALL_DIR}"
    docker compose pull --quiet

    log_step "Starting HoneyStack services..."
    docker compose up -d

    log_info "Services started."
}

###############################################################################
# Health checks
###############################################################################
health_check() {
    log_step "Running health checks..."
    local max_wait=60
    local waited=0

    # Wait for Grafana
    echo -n "  Waiting for Grafana"
    while ! curl -sf http://localhost:${GRAFANA_PORT}/api/health &>/dev/null; do
        echo -n "."
        sleep 3
        waited=$((waited + 3))
        if [[ ${waited} -ge ${max_wait} ]]; then
            echo ""
            log_warn "Grafana did not become healthy within ${max_wait}s. Check 'docker logs honeystack-grafana'"
            break
        fi
    done
    if [[ ${waited} -lt ${max_wait} ]]; then
        echo ""
        log_info "Grafana is healthy."
    fi

    # Check all containers
    echo ""
    log_step "Container status:"
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

    # Verify Cowrie is listening
    if ss -tlnp | grep -q ":${COWRIE_SSH_PORT:-2222}"; then
        log_info "Cowrie SSH is listening on port ${COWRIE_SSH_PORT:-2222}."
    else
        log_warn "Cowrie SSH port ${COWRIE_SSH_PORT:-2222} not detected. Container may still be starting."
    fi
}

###############################################################################
# Print summary
###############################################################################
print_summary() {
    local grafana_pass
    grafana_pass=$(grep GRAFANA_ADMIN_PASSWORD "${INSTALL_DIR}/.env" | cut -d= -f2)

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║             HoneyStack Installation Complete                ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║${NC}  SSH Management Port:  ${CYAN}${SSH_PORT}${NC}                                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Connect with: ${CYAN}ssh -p ${SSH_PORT} user@host${NC}                       ${GREEN}║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║${NC}  Grafana Dashboard:   ${CYAN}http://<your-ip>:${GRAFANA_PORT}${NC}                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Username: ${CYAN}admin${NC}                                           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Password: ${CYAN}${grafana_pass}${NC}                                     ${GREEN}║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║${NC}  Honeypots Enabled:   ${CYAN}${ENABLED_HONEYPOTS}${NC}                                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Cowrie SSH:    port 22 → ${COWRIE_SSH_PORT:-2222}                           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Cowrie Telnet: port 23 → ${COWRIE_TELNET_PORT:-2223}                           ${GREEN}║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║${NC}  Install Dir: ${CYAN}${INSTALL_DIR}${NC}                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Log Dir:     ${CYAN}${LOG_DIR}${NC}                          ${GREEN}║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║${NC}  Useful Commands:                                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    View logs:   ${CYAN}cd ${INSTALL_DIR} && docker compose logs -f${NC}  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Stop:        ${CYAN}cd ${INSTALL_DIR} && docker compose down${NC}     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Start:       ${CYAN}cd ${INSTALL_DIR} && docker compose up -d${NC}    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Uninstall:   ${CYAN}sudo ./uninstall.sh${NC}                          ${GREEN}║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Mark as installed
    date > "${INSTALL_DIR}/.installed"
    echo "${ENABLED_HONEYPOTS}" >> "${INSTALL_DIR}/.installed"
}

###############################################################################
# Main
###############################################################################
main() {
    echo ""
    echo -e "${CYAN}  _   _                        ____  _             _    ${NC}"
    echo -e "${CYAN} | | | | ___  _ __   ___ _   _/ ___|| |_ __ _  ___| | __${NC}"
    echo -e "${CYAN} | |_| |/ _ \\| '_ \\ / _ \\ | | \\___ \\| __/ _\` |/ __| |/ /${NC}"
    echo -e "${CYAN} |  _  | (_) | | | |  __/ |_| |___) | || (_| | (__|   < ${NC}"
    echo -e "${CYAN} |_| |_|\\___/|_| |_|\\___|\\__, |____/ \\__\\__,_|\\___|_|\\_\\${NC}"
    echo -e "${CYAN}                          |___/                          ${NC}"
    echo -e "${CYAN} Lightweight Modular Honeypot Platform${NC}"
    echo ""

    preflight_checks
    load_config
    install_docker
    install_iptables
    reconfigure_ssh
    setup_iptables
    create_directories
    copy_files
    generate_compose
    start_services
    health_check
    print_summary
}

main "$@"
