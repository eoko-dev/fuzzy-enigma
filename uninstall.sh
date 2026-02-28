#!/usr/bin/env bash
# HoneyStack - Uninstaller
set -euo pipefail

INSTALL_DIR="/opt/honeystack"
LOG_DIR="/var/log/honeypots"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[+]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_step()  { echo -e "${CYAN}[*]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[-] This script must be run as root (use sudo)${NC}"
    exit 1
fi

echo ""
echo -e "${RED}  HoneyStack Uninstaller${NC}"
echo ""

###############################################################################
# Load config if present
###############################################################################
if [[ -f "${INSTALL_DIR}/honeystack.conf" ]]; then
    # shellcheck source=/dev/null
    source "${INSTALL_DIR}/honeystack.conf"
fi
SSH_PORT="${SSH_PORT:-22222}"

###############################################################################
# Stop containers
###############################################################################
log_step "Stopping HoneyStack containers..."
if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    cd "${INSTALL_DIR}"
    docker compose down --remove-orphans 2>/dev/null || true
    log_info "Containers stopped and removed."
else
    log_warn "No docker-compose.yml found at ${INSTALL_DIR}. Skipping container stop."
fi

###############################################################################
# Remove iptables rules
###############################################################################
log_step "Removing iptables rules..."
iptables -t nat -S PREROUTING 2>/dev/null | grep "honeystack" | while read -r rule; do
    iptables -t nat $(echo "${rule}" | sed 's/-A/-D/') 2>/dev/null || true
done

if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>/dev/null || true
elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
log_info "iptables rules removed."

###############################################################################
# Restore SSH
###############################################################################
log_step "Restoring SSH configuration..."
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="${SSHD_CONFIG}.honeystack.bak"

if [[ -f "${SSHD_BACKUP}" ]]; then
    cp "${SSHD_BACKUP}" "${SSHD_CONFIG}"
    rm -f "${SSHD_BACKUP}"

    if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart ssh
    fi
    log_info "SSH restored to original configuration."
else
    # Manual restore if no backup
    if grep -q "^Port ${SSH_PORT}" "${SSHD_CONFIG}" 2>/dev/null; then
        sed -i "s/^Port ${SSH_PORT}/Port 22/" "${SSHD_CONFIG}"
        if systemctl is-active --quiet sshd 2>/dev/null; then
            systemctl restart sshd
        elif systemctl is-active --quiet ssh 2>/dev/null; then
            systemctl restart ssh
        fi
        log_info "SSH port restored to 22."
    else
        log_warn "SSH config not modified (no backup found and port not matching)."
    fi
fi

###############################################################################
# Clean up data (optional)
###############################################################################
echo ""
read -rp "Remove all honeypot data and logs? [y/N]: " remove_data
if [[ "${remove_data}" == "y" || "${remove_data}" == "Y" ]]; then
    log_step "Removing data and logs..."
    rm -rf "${LOG_DIR}"
    log_info "Log directory removed: ${LOG_DIR}"

    # Remove Docker volumes
    docker volume ls --format '{{.Name}}' | grep -E "honeystack" | while read -r vol; do
        docker volume rm "${vol}" 2>/dev/null || true
    done
    log_info "Docker volumes removed."
fi

###############################################################################
# Remove install directory
###############################################################################
read -rp "Remove installation directory (${INSTALL_DIR})? [y/N]: " remove_install
if [[ "${remove_install}" == "y" || "${remove_install}" == "Y" ]]; then
    rm -rf "${INSTALL_DIR}"
    log_info "Installation directory removed."
fi

###############################################################################
# Remove Docker images (optional)
###############################################################################
read -rp "Remove Docker images (cowrie, grafana, loki, promtail)? [y/N]: " remove_images
if [[ "${remove_images}" == "y" || "${remove_images}" == "Y" ]]; then
    log_step "Removing Docker images..."
    docker rmi cowrie/cowrie:latest 2>/dev/null || true
    docker rmi grafana/grafana:10.3.1 2>/dev/null || true
    docker rmi grafana/loki:2.9.4 2>/dev/null || true
    docker rmi grafana/promtail:2.9.4 2>/dev/null || true
    log_info "Docker images removed."
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          HoneyStack has been uninstalled.               ║${NC}"
echo -e "${GREEN}║          SSH has been restored to port 22.              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
