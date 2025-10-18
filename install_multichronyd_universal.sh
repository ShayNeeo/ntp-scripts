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

# --- THE COMPREHENSIVE STRATUM 1 NTP SERVER LIST (as of 2025) ---
# Curated from all provided sources for maximum reliability and geographic performance.
STRATUM_1_SERVERS=(
    # --- Top Tier Global Anycast Providers ---
    "time.google.com"
    "time.cloudflare.com"
    "time.facebook.com"
    "time.apple.com"
    "time.aws.com"
    "time.windows.com"
    "ntp.se"                  # Netnod (Anycast)

    # --- National Time Authorities (Geographically Diverse) ---
    "ntp.nict.jp"             # NICT (Japan) - Excellent for Asia
    "ntp.ntsc.ac.cn"          # NTSC (China) - Excellent for Asia
    "stdtime.gov.hk"          # Hong Kong Time Standard
    "time.nplindia.org"       # NPL (India)
    "time-a-g.nist.gov"       # NIST (USA)
    "tick.usno.navy.mil"      # US Naval Observatory
    "ptbtime1.ptb.de"         # PTB (Germany)

    # --- Highly Reliable Infrastructure & Academic Servers ---
    "clock.sjc.he.net"        # Hurricane Electric (USA, West Coast)
    "ntp1.caltech.edu"        # Caltech (USA)
)

# --- Script Start ---
echo "=== Script run at $(date) ===" > "$LOG_FILE"
print_info "Starting Universal Multi-Instance Chrony & Firewall Setup"

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

# 3. Stop and Disable ALL Conflicting Services
print_action "Stopping all conflicting time services"
systemctl disable --now systemd-timesyncd ntpd chrony chronyd multichronyd &>/dev/null
print_success "Disabled all known time services to prevent conflicts."

# 4. Install Chrony
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

# 5. Firewall Setup (Install and Configure UFW)
print_info "${FIREWALL_EMOJI} Checking and configuring firewall..."
if systemctl is-active --quiet firewalld; then
    print_success "firewalld is already active. Will configure it."
    firewall-cmd --permanent --add-port=123/udp &>>"$LOG_FILE"
    firewall-cmd --reload &>>"$LOG_FILE"
    print_success "Opened port 123/udp on firewalld."
elif command -v ufw &>/dev/null; then
    print_success "UFW is already installed. Will configure it."
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
    print_success "Added UFW rule to allow SSH (important!)."
    ufw allow 123/udp &>>"$LOG_FILE"
    print_success "Added UFW rule to allow NTP on port 123/udp."
    echo "y" | ufw enable &>>"$LOG_FILE"
    print_success "UFW has been enabled."
fi


# 6. Interactive CPU Core Selection
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

# 7. Create the Main chrony.conf with Stratum 1 Sources
CHRONY_CONF="/etc/chrony/chrony.conf"
mkdir -p "$(dirname "$CHRONY_CONF")"
print_action "Creating main configuration at $CHRONY_CONF with comprehensive Stratum 1 servers"
cat << EOF > "$CHRONY_CONF"
# This file is managed by the multichrony setup script.
$(for server in "${STRATUM_1_SERVERS[@]}"; do echo "server $server iburst"; done)
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
allow
logdir /var/log/chrony
EOF
print_success "Main configuration file created."

# 8. Create the multichronyd.sh Script
print_action "Generating the /root/multichronyd.sh script"
cat << EOF > /root/multichronyd.sh
#!/bin/bash
servers=${CPU_CORES}
chronyd="/usr/sbin/chronyd"
trap terminate SIGINT SIGTERM
terminate() {
  for p in /var/run/chrony/chronyd*.pid; do
    pid=\$(cat "\$p" 2>/dev/null) && [[ "\$pid" =~ [0-9]+ ]] && kill "\$pid"
  done
}
conf="/etc/chrony/chrony.conf"
case "\$(\"\$chronyd\" --version | grep -o -E '[1-9]\.[0-9]+')" in
  1.*|2.*|3.*) echo "chrony version too old"; exit 1;;
  4.0) opts="";;
  4.1) opts="xleave copy";;
  *) opts="xleave copy extfield F323";;
esac
mkdir -p /var/run/chrony
for i in \$(seq 1 "\$servers"); do
  "\$chronyd" "\$@" -n -x \\
    "server 127.0.0.1 port 11123 minpoll 0 maxpoll 0 \$opts" \\
    "allow" "cmdport 0" \\
    "bindcmdaddress /var/run/chrony/chronyd-server\$i.sock" \\
    "pidfile /var/run/chrony/chronyd-server\$i.pid" &
done
"\$chronyd" "\$@" -n \\
  "include \$conf" \\
  "pidfile /var/run/chrony/chronyd-client.pid" \\
  "bindcmdaddress /var/run/chrony/chronyd-client.sock" \\
  "port 11123" "bindaddress 127.0.0.1" "sched_priority 1" "allow 127.0.0.1" &
wait
EOF
chmod +x /root/multichronyd.sh
print_success "Multi-instance script created and made executable."

# 9. Create the systemd Service File
print_action "Creating the multichronyd.service systemd file"
cat << 'EOF' > /etc/systemd/system/multichronyd.service
[Unit]
Description=Multi-Instance Chronyd Service Manager
After=network.target
[Service]
User=root
Group=root
ExecStart=/root/multichronyd.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
print_success "Systemd service file created."

# 10. Start the Multi-Chrony Service
print_action "Reloading systemd and starting multichronyd.service"
systemctl daemon-reload
systemctl enable --now multichronyd.service &>>"$LOG_FILE"
if ! systemctl is-active --quiet multichronyd; then
    print_error "Failed to start multichronyd.service. Check log: $LOG_FILE"; exit 1;
fi
print_success "Multi-instance chrony service is now active."

# 11. Configure Local Network Access
print_action "Detecting local subnets to configure server access"
SUBNETS=($(ip -o -f inet addr show | awk '/scope global/ {print $4}' | grep -v '127.0.0.1'))
if [ ${#SUBNETS[@]} -gt 0 ]; then
    print_info "Detected local subnets: ${SUBNETS[*]}"
    for SUBNET in "${SUBNETS[@]}"; do
        echo "allow $SUBNET" >> "$CHRONY_CONF"
    done
    print_action "Restarting service to apply local network access rules"
    systemctl restart multichronyd.service &>>"$LOG_FILE"
    print_success "Service restarted with new rules."
else
    print_info "No external local subnets detected. Running in client-only mode."
fi

# 12. Final Verification
print_action "Waiting a few seconds for sync..."
sleep 60
print_info "Final Sync Status (chronyc tracking):"
chronyc -h /var/run/chrony/chronyd-client.sock tracking | tee -a "$LOG_FILE"
print_info "Active Time Sources (chronyc sources):"
chronyc -h /var/run/chrony/chronyd-client.sock sources | tee -a "$LOG_FILE"

if ss -lupn | grep -q ":123"; then
    print_success "${SERVER_EMOJI} NTP service is up and listening on port 123."
else
    print_warning "NTP service is not listening on port 123. It may be in client-only mode or blocked."
fi

print_info "Setup complete!"
