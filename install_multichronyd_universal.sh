#!/bin/bash

# ANSI Colors & Emojis
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; CYAN="\033[0;36m"; RESET="\033[0m"
CHECK_EMOJI="✅"; ERROR_EMOJI="❌"; INFO_EMOJI="ℹ️"; SYNC_EMOJI="🔄"; SERVER_EMOJI="🛡️"; FIREWALL_EMOJI="🔥"

# Log file setup
LOG_FILE="/var/log/multichrony_setup.log"
touch "$LOG_FILE" &>/dev/null || LOG_FILE="/tmp/multichrony_setup.log"

# --- Helper Functions for Logging and Output ---
print_info() { echo -e "${BLUE}${INFO_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_success() { echo -e "${GREEN}${CHECK_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_error() { echo -e "${RED}${ERROR_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_warning() { echo -e "${YELLOW}${SYNC_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_action() { echo -e "${CYAN}${SYNC_EMOJI} $1...${RESET}" | tee -a "$LOG_FILE"; }

# --- THE COMPREHENSIVE STRATUM 1 NTP SERVER LIST ---
STRATUM_1_SERVERS=(
    "time.google.com" "time.cloudflare.com" "time.facebook.com" "time.apple.com" "time.aws.com" "time.windows.com" "ntp.se"
    "ntp.nict.jp" "ntp.ntsc.ac.cn" "stdtime.gov.hk" "time.nplindia.org"
    "time-a-g.nist.gov" "tick.usno.navy.mil" "ptbtime1.ptb.de"
    "clock.sjc.he.net" "ntp1.caltech.edu"
)

# --- Script Start ---
echo "=== Script run at $(date) ===" > "$LOG_FILE"
print_info "Starting NTP Pool Ready Multi-Instance Chrony & Firewall Setup"

# 1. Root Check & System Detection
if [[ $EUID -ne 0 ]]; then print_error "This script must be run as root (sudo)."; exit 1; fi
print_action "Detecting system and package manager"
if [ -f /etc/os-release ]; then . /etc/os-release; fi
DISTRO=${NAME:-"Unknown"}
PACKAGE_MANAGER=""
if command -v apt &>/dev/null; then PACKAGE_MANAGER="apt"; elif command -v dnf &>/dev/null; then PACKAGE_MANAGER="dnf"; elif command -v yum &>/dev/null; then PACKAGE_MANAGER="yum"; elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman"; elif command -v apk &>/dev/null; then PACKAGE_MANAGER="apk"; else print_error "Unsupported package manager."; exit 1; fi
print_success "System: $DISTRO, Package Manager: $PACKAGE_MANAGER"

# 2. Stop/Disable Conflicting Services
print_action "Stopping all conflicting time services"
systemctl disable --now systemd-timesyncd ntpd chrony chronyd multichronyd &>/dev/null
print_success "Disabled all known time services."

# 3. Install Chrony
if ! command -v chronyd &>/dev/null; then
    print_action "Installing chrony"
    case "$PACKAGE_MANAGER" in
        apt) apt-get update -y && apt-get install -y chrony &>>"$LOG_FILE";;
        dnf|yum) dnf install -y chrony &>>"$LOG_FILE";;
        pacman) pacman -S --noconfirm chrony &>>"$LOG_FILE";;
        apk) apk add chrony &>>"$LOG_FILE";;
    esac
    if ! command -v chronyd &>/dev/null; then print_error "Chrony installation failed. Check log: $LOG_FILE"; exit 1; fi
    print_success "Chrony has been installed."
else
    print_success "Chrony is already installed."
fi

# 4. Firewall Setup (UFW)
print_info "${FIREWALL_EMOJI} Checking and configuring firewall..."
if ! command -v ufw &>/dev/null; then
    print_action "Installing UFW (Uncomplicated Firewall)"
    case "$PACKAGE_MANAGER" in
        apt) apt-get install -y ufw &>>"$LOG_FILE";;
        dnf|yum) dnf install -y ufw &>>"$LOG_FILE";;
        pacman) pacman -S --noconfirm ufw &>>"$LOG_FILE";;
        *) print_warning "UFW installation not automated for this OS.";;
    esac
fi
if command -v ufw &>/dev/null; then
    ufw allow ssh &>>"$LOG_FILE"
    ufw allow 123/udp &>>"$LOG_FILE"
    echo "y" | ufw enable &>>"$LOG_FILE"
    print_success "Firewall configured to allow SSH and NTP."
fi

# 5. Interactive CPU Core Selection
print_action "Configuring CPU core usage"
TOTAL_CORES=$(nproc)
while true; do
    read -p "Enter the number of CPU cores to use (1-${TOTAL_CORES}, default: ${TOTAL_CORES}): " CPU_CORES
    CPU_CORES=${CPU_CORES:-$TOTAL_CORES}
    if [[ "$CPU_CORES" =~ ^[1-9][0-9]*$ ]] && [ "$CPU_CORES" -le "$TOTAL_CORES" ]; then
        print_success "Using $CPU_CORES core(s) for chrony server instances."
        break
    else
        print_error "Invalid input. Please enter a number between 1 and ${TOTAL_CORES}."
    fi
done

# 6. Create the NTP Pool Ready chrony.conf
CHRONY_CONF="/etc/chrony/chrony.conf"
mkdir -p "$(dirname "$CHRONY_CONF")"
print_action "Creating NTP Pool ready configuration at $CHRONY_CONF"
cat << EOF > "$CHRONY_CONF"
# This file is managed by the multichrony setup script for the NTP Pool Project.
$(for server in "${STRATUM_1_SERVERS[@]}"; do echo "server $server iburst"; done)

# --- NTP POOL ---
allow # Allow the pool's monitoring servers to connect.
log measurements statistics tracking  # Recommended logging for diagnostics.

# Basic settings
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
print_success "Main configuration file created."

# 7. Create the multichronyd.sh Script
print_action "Generating the /root/multichronyd.sh script"
cat << EOF > /root/multichronyd.sh
#!/bin/bash
servers=${CPU_CORES}
chronyd="/usr/sbin/chronyd"
trap terminate SIGINT SIGTERM
terminate() { for p in /var/run/chrony/chronyd*.pid; do pid=\$(cat "\$p" 2>/dev/null) && [[ "\$pid" =~ [0-9]+ ]] && kill "\$pid"; done; }
conf="/etc/chrony/chrony.conf"
case "\$(\"\$chronyd\" --version | grep -o -E '[1-9]\.[0-9]+')" in
  1.*|2.*|3.*) echo "chrony version too old"; exit 1;;
  4.0) opts="";; 4.1) opts="xleave copy";; *) opts="xleave copy extfield F323";;
esac
mkdir -p /var/run/chrony
for i in \$(seq 1 "\$servers"); do
  "\$chronyd" "\$@" -n -x "server 127.0.0.1 port 11123 minpoll 0 maxpoll 0 \$opts" "allow" "cmdport 0" "bindcmdaddress /var/run/chrony/chronyd-server\$i.sock" "pidfile /var/run/chrony/chronyd-server\$i.pid" &
done
"\$chronyd" "\$@" -n "include \$conf" "pidfile /var/run/chrony/chronyd-client.pid" "bindcmdaddress /var/run/chrony/chronyd-client.sock" "port 11123" "bindaddress 127.0.0.1" "sched_priority 1" "allow 127.0.0.1" &
wait
EOF
chmod +x /root/multichronyd.sh
print_success "Multi-instance script created."

# 8. Create the systemd Service File and Start Service
print_action "Creating and starting the multichronyd.service"
cat << 'EOF' > /etc/systemd/system/multichronyd.service
[Unit]
Description=Multi-Instance Chronyd Service Manager
After=network.target
[Service]
User=root; Group=root; ExecStart=/root/multichronyd.sh; Restart=always; RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now multichronyd.service &>>"$LOG_FILE"
if ! systemctl is-active --quiet multichronyd; then print_error "Failed to start multichronyd.service. Check log: $LOG_FILE"; exit 1; fi
print_success "Multi-instance chrony service is now active."

# 9. Configure Local Network Access
print_action "Detecting local subnets to configure server access"
SUBNETS=($(ip -o -f inet addr show | awk '/scope global/ {print $4}' | grep -v '127.0.0.1'))
if [ ${#SUBNETS[@]} -gt 0 ]; then
    print_info "Detected local subnets: ${SUBNETS[*]}"
    for SUBNET in "${SUBNETS[@]}"; do echo "allow $SUBNET" >> "$CHRONY_CONF"; done
    systemctl restart multichronyd.service &>>"$LOG_FILE"
    print_success "Service restarted with local network access rules."
fi

# 10. Final Verification
print_action "Waiting a few seconds for sync..."
sleep 15
print_info "Final Sync Status (chronyc tracking):"
chronyc -h /var/run/chrony/chronyd-client.sock tracking | tee -a "$LOG_FILE"
print_info "Active Time Sources (chronyc sources):"
chronyc -h /var/run/chrony/chronyd-client.sock sources | tee -a "$LOG_FILE"
if ss -lupn | grep -q ":123"; then print_success "${SERVER_EMOJI} NTP service is up and listening on port 123."; fi
print_info "Setup complete!"