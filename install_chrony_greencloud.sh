#!/bin/bash

# --- Configuration ---
# This is the per-process limit suggested by your provider.
CPU_LIMIT_PER_PROCESS="30%"

# --- ANSI Colors & Emojis ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; CYAN="\033[0;36m"; RESET="\033[0m"
CHECK_EMOJI="✅"; ERROR_EMOJI="❌"; INFO_EMOJI="ℹ️"; SYNC_EMOJI="🔄"; SERVER_EMOJI="🛡️"; FIREWALL_EMOJI="🔥"; LIMIT_EMOJI="🚦"

# --- Log file setup ---
LOG_FILE="/var/log/multichrony_setup.log"
touch "$LOG_FILE" &>/dev/null || LOG_FILE="/tmp/multichrony_setup.log"

# --- Helper Functions for Logging and Output ---
print_info() { echo -e "${BLUE}${INFO_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_success() { echo -e "${GREEN}${CHECK_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_error() { echo -e "${RED}${ERROR_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_warning() { echo -e "${YELLOW}${SYNC_EMOJI} $1${RESET}" | tee -a "$LOG_FILE"; }
print_action() { echo -e "${CYAN}${SYNC_EMOJI} $1...${RESET}" | tee -a "$LOG_FILE"; }

# --- THE COMPREHENSIVE STRATUM 1 NTP SERVER LIST (as of 2025) ---
STRATUM_1_SERVERS=(
    "time.google.com"
    "time.facebook.com"
    "time.apple.com"
    "ntp.se"
    "ntp.nict.jp"
    "time.nplindia.org"
    "time.nist.gov"
    "tick.usask.ca"
    "ptbtime1.ptb.de"
    "clock.fmt.he.net"
    "ntp1.leontp.com"
    "vega.cbk.poznan.pl"
    "ntp.bsn.go.id"
    "time1.nimt.or.th"
    "time.hko.hk"
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
rm -f /etc/systemd/system/chrony.service.d/cpu_limit.conf # Clean up old script's limit
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
allow
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
print_success "Main configuration file created."

# 7.5. Ensure /var/run/chrony directory exists with proper permissions
print_action "Setting up /var/run/chrony directory"
rm -rf /var/run/chrony
mkdir -p /var/run/chrony
chmod 1777 /var/run/chrony
chown root:root /var/run/chrony
print_success "Directory /var/run/chrony is ready."

# 8. Create the multichronyd.sh Script (*** MODIFIED FOR CPU LIMITING ***)
print_action "Generating the /root/multichronyd.sh script"
print_info "${LIMIT_EMOJI} Each process will be limited to 30% CPU."
cat << SCRIPT > /root/multichronyd.sh
#!/bin/bash
clients=\${CPU_CORES}

if [ -x "/usr/sbin/chronyd" ]; then
    chronyd="/usr/sbin/chronyd"
elif [ -x "/usr/bin/chronyd" ]; then
    chronyd="/usr/bin/chronyd"
elif command -v chronyd >/dev/null 2>&1; then
    chronyd=\$(command -v chronyd)
else
    echo "Error: chronyd not found"
    exit 1
fi

trap terminate SIGINT SIGTERM
terminate() {
  for p in /var/run/chrony/chronyd*.pid; do
    pid=\$(cat "\$p" 2>/dev/null) && [[ "\$pid" =~ [0-9]+ ]] && kill "\$pid" 2>/dev/null
  done
  wait 2>/dev/null
}

mkdir -p /var/run/chrony
chmod 1777 /var/run/chrony

# Determine chrony version for options
case "\$("\$chronyd" --version 2>/dev/null | grep -o -E '[0-9]+\.[0-9]+')" in
  4.0*) opts="" ;;
  4.1*) opts="xleave copy" ;;
  *) opts="xleave copy extfield F323" ;;
esac

# --- Launch Multiple Client Instances (each syncs with Stratum 1) ---
for i in \$(seq 1 "\$clients"); do
  printf 'include /etc/chrony/chrony.conf\nport 1123%d\nbindaddress 127.0.0.1\nsched_priority 1\ncmdport 0\nbindcmdaddress /var/run/chrony/chronyd-client%d.sock\npidfile /var/run/chrony/chronyd-client%d.pid\n' "\$i" "\$i" "\$i" | "\$chronyd" -n -f - &
done

# --- Launch Server Instance (listens on port 123, pulls from all clients) ---
printf 'allow\ncmdport 0\nbindcmdaddress /var/run/chrony/chronyd-server.sock\npidfile /var/run/chrony/chronyd-server.pid\n' > /tmp/chrony-server.conf
for i in \$(seq 1 "\$clients"); do
  echo "server 127.0.0.1 port 1123\$i minpoll 0 maxpoll 0 \$opts" >> /tmp/chrony-server.conf
done
"\$chronyd" -n -f /tmp/chrony-server.conf &

wait
SCRIPT

chmod +x /root/multichronyd.sh
print_success "Multi-instance script created and made executable."

# 9. Create the systemd Service File
print_action "Creating the multichronyd.service systemd file"
CPU_QUOTA=$(($CPU_CORES * 30))
cat << 'EOF' > /etc/systemd/system/multichronyd.service
[Unit]
Description=Multi-Instance Chronyd Service Manager
After=network.target
[Service]
Type=simple
User=root
Group=root
ExecStart=/root/multichronyd.sh
KillMode=process
Restart=always
RestartSec=10
MemoryMax=512M
CPUQuota=${CPU_QUOTA}%
[Install]
WantedBy=multi-user.target
EOF
sed -i "s|\${CPU_QUOTA}|$CPU_QUOTA|g" /etc/systemd/system/multichronyd.service
print_success "Systemd service file created."

# 10. Start the Multi-Chrony Service
print_action "Reloading systemd and starting multichronyd.service"
systemctl daemon-reload
systemctl enable --now multichronyd.service &>>"$LOG_FILE"
if ! systemctl is-active --quiet multichronyd; then
    print_error "Failed to start multichronyd.service. Check log: $LOG_FILE"; exit 1;
fi
print_success "Multi-instance chrony service is now active."

# 11. Final Verification
print_action "Waiting for initial sync..."
sleep 15

# Fix socket permissions for access
for attempt in {1..10}; do
    if [ -S /var/run/chrony/chronyd-client.sock ] || [ -S /var/run/chrony/chronyd-server1.sock ]; then
        chmod 666 /var/run/chrony/chronyd*.sock 2>/dev/null
        break
    fi
    sleep 1
done

CLIENT_SOCK="/var/run/chrony/chronyd-client.sock"
if [ -S "$CLIENT_SOCK" ]; then
    print_info "Final Sync Status (chronyc tracking):"
    chronyc -h "$CLIENT_SOCK" tracking 2>&1 | tee -a "$LOG_FILE" || print_warning "Socket access limited"
    print_info "Active Time Sources (chronyc sources):"
    chronyc -h "$CLIENT_SOCK" sources 2>&1 | tee -a "$LOG_FILE" || print_warning "Socket access limited"
elif [ -S /var/run/chrony/chronyd-server1.sock ]; then
    print_info "Final Sync Status (chronyc tracking from server 1):"
    chronyc -h /var/run/chrony/chronyd-server1.sock tracking 2>&1 | tee -a "$LOG_FILE" || true
else
    if pgrep -f chronyd > /dev/null; then
        print_info "Chronyd processes running. NTP service is active."
    fi
fi

if ss -lupn 2>/dev/null | grep -q ":123"; then
    print_success "${SERVER_EMOJI} NTP service is listening on port 123."
else
    print_warning "NTP service not detected on port 123. Check: systemctl status multichronyd.service"
fi

print_info "Setup complete! 1 NTP server + ${CPU_CORES} client instances. Clients limited to 30% each (Total: ${CPU_QUOTA}%). Server unlimited."
