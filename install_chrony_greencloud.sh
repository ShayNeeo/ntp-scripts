#!/bin/bash

# --- Configuration ---
# This is the most important setting.
# It matches your provider's ToS (30% average).
CPU_LIMIT="30%"

# --- ANSI Colors & Emojis ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; CYAN="\033[0;36m"; RESET="\033[0m"
CHECK_EMOJI="✅"; ERROR_EMOJI="❌"; INFO_EMOJI="ℹ️"; SYNC_EMOJI="🔄"; SERVER_EMOJI="🛡️"; FIREWALL_EMOJI="🔥"; LIMIT_EMOJI="🚦"

# --- Log file setup ---
LOG_FILE="/var/log/safe_chrony_setup.log"
touch "$LOG_FILE" &>/dev/null || LOG_FILE="/tmp/safe_chrony_setup.log"

# --- Helper Functions for Logging and Output ---
print_info() { echo -e "${BLUE}${INFO_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_success() { echo -e "${GREEN}${CHECK_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_error() { echo -e "${RED}${ERROR_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_warning() { echo -e "${YELLOW}${SYNC_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_action() { echo -e "${CYAN}${SYNC_EMOJI} $1...${RESET}" | tee -a "$LOG_FILE"; }

# --- Script Start ---
echo "=== Safe Chrony Setup run at $(date) ===" > "$LOG_FILE"
print_info "Starting ToS-Compliant Single-Instance Chrony Setup"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (sudo)."
    exit 1
fi

# 2. System and Package Manager Detection
print_action "Detecting system and package manager"
if [ -f /etc/os-release ]; then . /etc/os-release; fi
DISTRO=${NAME:-"Unknown"}
PACKAGE_MANAGER=""
if command -v apt &>/dev/null; then PACKAGE_MANAGER="apt";
elif command -v dnf &>/dev/null; then PACKAGE_MANAGER="dnf";
elif command -v yum &>/dev/null; then PACKAGE_MANAGER="yum";
elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman";
elif command -v apk &>/dev/null; then PACKAGE_MANAGER="apk";
else print_error "Unsupported package manager."; exit 1; fi
print_success "System: $DISTRO, Package Manager: $PACKAGE_MANAGER"

# 3. Stop and Remove ALL Conflicting Services/Files
print_action "Stopping and disabling all conflicting time services"
# Stop your custom service, systemd's, ntpd, and any standard chrony
systemctl disable --now multichronyd systemd-timesyncd ntpd chrony chronyd &>/dev/null
print_success "Disabled all known time services."

print_action "Removing old multichrony script and service files"
rm -f /root/multichronyd.sh
rm -f /etc/systemd/system/multichronyd.service
systemctl daemon-reload
print_success "Removed old multichrony files."

# 4. Install Standard Chrony
if ! command -v chronyd &>/dev/null; then
    print_action "Installing standard chrony package"
    case "$PACKAGE_MANAGER" in
        apt) apt-get update -y && apt-get install -y chrony &>>"$LOG_FILE";;
        dnf|yum) dnf install -y chrony &>>"$LOG_FILE";;
        pacman) pacman -S --noconfirm chrony &>>"$LOG_FILE";;
        apk) apk add chrony &>>"$LOG_FILE";;
    esac
    if ! command -v chronyd &>/dev/null; then print_error "Chrony installation failed. Check log: $LOG_FILE"; exit 1; fi
    print_success "Standard Chrony has been installed."
else
    print_success "Standard Chrony is already installed."
fi

# 5. Create Low-CPU chrony.conf
print_action "Creating low-CPU configuration at /etc/chrony/chrony.conf"
cat << EOF > /etc/chrony/chrony.conf
# This is a low-CPU configuration to comply with VPS ToS.
# It checks servers less frequently (minpoll 8 = 256s, maxpoll 12 = 4096s).

server time.google.com     iburst minpoll 8 maxpoll 12
server time.facebook.com   iburst minpoll 8 maxpoll 12
server time.apple.com      iburst minpoll 8 maxpoll 12
server ntp.se              iburst minpoll 8 maxpoll 12

# Standard settings
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
allow
EOF
print_success "Low-CPU chrony.conf created."

# 6. CRITICAL: Enforce 30% CPU Limit
print_action "${LIMIT_EMOJI} Enforcing ${CPU_LIMIT} CPU limit via systemd..."

# Find the correct service name (Debian/Ubuntu use 'chrony.service', RHEL/Arch use 'chronyd.service')
SERVICE_NAME="chrony.service"
if [ "$PACKAGE_MANAGER" == "dnf" ] || [ "$PACKAGE_MANAGER" == "yum" ] || [ "$PACKAGE_MANAGER" == "pacman" ]; then
    SERVICE_NAME="chronyd.service"
fi
print_info "Targeting service: $SERVICE_NAME"

# Create the systemd drop-in file to apply the limit
DROP_IN_DIR="/etc/systemd/system/${SERVICE_NAME}.d"
mkdir -p "$DROP_IN_DIR"
cat << EOF > "${DROP_IN_DIR}/cpu_limit.conf"
[Service]
# This enforces the provider's 30% CPU quota.
CPUQuota=${CPU_LIMIT}
EOF
print_success "Set CPUQuota=${CPU_LIMIT} for ${SERVICE_NAME}."

# 7. Firewall Setup (Re-using your solid logic)
print_info "${FIREWALL_EMOJI} Checking and configuring firewall..."
if systemctl is-active --quiet firewalld; then
    print_success "firewalld is active. Configuring it."
    firewall-cmd --permanent --add-port=123/udp &>>"$LOG_FILE"
    firewall-cmd --reload &>>"$LOG_FILE"
    print_success "Opened port 123/udp on firewalld."
elif command -v ufw &>/dev/null; then
    print_success "UFW is already installed. Configuring it."
else
    print_action "No active firewall found. Installing UFW"
    case "$PACKAGE_MANAGER" in
        apt) apt-get install -y ufw &>>"$LOG_FILE";;
        dnf|yum) dnf install -y ufw &>>"$LOG_FILE";;
        pacman) pacman -S --noconfirm ufw &>>"$LOG_FILE";;
        *) print_warning "UFW installation not automated for this OS. Please install it manually.";;
    esac
    if ! command -v ufw &>/dev/null; then print_error "UFW installation failed."; fi
    print_success "UFW has been installed."
fi

if command -v ufw &>/dev/null; then
    print_action "Configuring UFW rules"
    ufw allow ssh &>>"$LOG_FILE"
    print_success "Added UFW rule to allow SSH."
    ufw allow 123/udp &>>"$LOG_FILE"
    print_success "Added UFW rule to allow NTP on port 123/udp."
    echo "y" | ufw enable &>>"$LOG_FILE"
    print_success "UFW has been enabled."
fi

# 8. Start the Standard Chrony Service
print_action "Reloading systemd and starting ${SERVICE_NAME}"
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME} &>>"$LOG_FILE"
if ! systemctl is-active --quiet ${SERVICE_NAME}; then
    print_error "Failed to start ${SERVICE_NAME}. Check log: $LOG_FILE"; exit 1;
fi
print_success "Standard chrony service is now active and running."

# 9. Final Verification
print_action "Waiting 20 seconds for first sync attempt..."
sleep 20
print_info "Final Sync Status (chronyc tracking):"
chronyc tracking | tee -a "$LOG_FILE"
print_info "Active Time Sources (chronyc sources):"
chronyc sources | tee -a "$LOG_FILE"

if ss -lupn | grep -q ":123"; then
    print_success "${SERVER_EMOJI} NTP service is up and listening on port 123."
else
    print_warning "NTP service is not listening on port 123. (This is OK if you don't need to be a public server)."
fi

print_success "Setup complete! Chrony is now running and limited to ${CPU_LIMIT} CPU."
