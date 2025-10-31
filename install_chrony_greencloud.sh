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
    "time.facebook.com"
    "time.apple.com"
    "ntp.se"                  # Netnod (Anycast)

    # --- National Time Authorities (Geographically Diverse) ---
    "ntp.nict.jp"             # NICT (Japan) - Excellent for Asia
    "time.nplindia.org"       # NPL (India)
    "time.nist.gov"           # NIST (USA)
#    "tick.usno.navy.mil"      # US Naval Observatory
#    "tock.usno.navy.mil"      # US Naval Observatory
    "tick.usask.ca"           # USASK (Canada)
#    "tock.usask.ca"           # USASK (Canada)
    "ptbtime1.ptb.de"         # PTB (Germany)

    # --- Highly Reliable Infrastructure & Academic Servers ---
    "clock.fmt.he.net"        # Hurricane Electric (USA, East Coast)
    "ntp1.leontp.com"         # LEON-TP (France)
    "vega.cbk.poznan.pl"      # CBK (Poland)
    "ntp.bsn.go.id"           # BSN (Indonesia)
    "time1.nimt.or.th"        # NIMT (Thailand)
#    "time2.nimt.or.th"        # NIMT (Thailand)
#    "time3.nimt.or.th"        # NIMT (Thailand)
    "time.hko.hk"             # HK Observatory (Hong Kong)
)

# --- Script Start ---
echo "=== Script run at $(date) ===" > "$LOG_FILE"
print_info "Starting Greencloud Multi-Instance Chrony Setup with CPU Limits (2 cores, 2 server instances @ 30% each)"

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

# 5. Install cpulimit for CPU limiting
if ! command -v cpulimit &>/dev/null; then
    print_action "Installing cpulimit for CPU limiting"
    case "$PACKAGE_MANAGER" in
        apt) apt-get install -y cpulimit &>>"$LOG_FILE";;
        dnf|yum) dnf install -y cpulimit &>>"$LOG_FILE";;
        pacman) pacman -S --noconfirm cpulimit &>>"$LOG_FILE";;
        apk) apk add cpulimit &>>"$LOG_FILE";;
    esac
    if ! command -v cpulimit &>/dev/null; then
        print_error "cpulimit installation failed. CPU limiting will not work. Check log: $LOG_FILE"
        exit 1
    fi
    print_success "cpulimit has been installed."
else
    print_success "cpulimit is already installed."
fi

# 6. Firewall Setup (Install and Configure UFW)
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

# 7. Configure for 2 CPU cores (hardcoded for greencloud)
CPU_CORES=2
print_info "Configured for 2 CPU cores VPS:"
print_info "  - chrony (client): no CPU limit"
print_info "  - _chrony (2 server instances): 30% CPU limit each (total: 60%)"

# 8. Create the Main chrony.conf with Stratum 1 Sources
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

# 9. Create the multichronyd.sh Script with CPU Limits
print_action "Generating the /root/multichronyd.sh script with CPU limits"
cat << EOF > /root/multichronyd.sh
#!/bin/bash
servers=${CPU_CORES}
CPU_LIMIT_PERCENT=30

# Find chronyd dynamically
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

# Find cpulimit dynamically
if [ -x "/usr/bin/cpulimit" ]; then
    cpulimit="/usr/bin/cpulimit"
elif [ -x "/usr/local/bin/cpulimit" ]; then
    cpulimit="/usr/local/bin/cpulimit"
elif command -v cpulimit >/dev/null 2>&1; then
    cpulimit=\$(command -v cpulimit)
else
    echo "Error: cpulimit not found"
    exit 1
fi

trap terminate SIGINT SIGTERM
terminate() {
  # Kill cpulimit processes first
  pkill -f "cpulimit.*chronyd-server" 2>/dev/null
  for p in /var/run/chrony/chronyd*.pid; do
    pid=\$(cat "\$p" 2>/dev/null) && [[ "\$pid" =~ [0-9]+ ]] && kill "\$pid" 2>/dev/null
  done
  wait 2>/dev/null
}

conf="/etc/chrony/chrony.conf"
case "\$("\$chronyd" --version | grep -o -E '[1-9]\.[0-9]+')" in
  1.*|2.*|3.*) echo "chrony version too old"; exit 1;;
  4.0) opts="";;
  4.1) opts="xleave copy";;
  *) opts="xleave copy extfield F323";;
esac
mkdir -p /var/run/chrony
chmod 1777 /var/run/chrony

# Server instances: listen on port 123 (default) for public access with 'allow'
# They get time from the client instance on port 11123
# Each server instance is limited to CPU_LIMIT_PERCENT% CPU
for i in \$(seq 1 "\$servers"); do
  "\$chronyd" "\$@" -n -x \\
    "server 127.0.0.1 port 11123 minpoll 0 maxpoll 0 \$opts" \\
    "allow" "cmdport 0" \\
    "bindcmdaddress /var/run/chrony/chronyd-server\$i.sock" \\
    "pidfile /var/run/chrony/chronyd-server\$i.pid" &
  
  # Apply CPU limit to this server instance
  # Retry loop to ensure PID file exists and limit is applied
  for retry in {1..10}; do
    if [ -f "/var/run/chrony/chronyd-server\$i.pid" ]; then
      pid=\$(cat "/var/run/chrony/chronyd-server\$i.pid" 2>/dev/null)
      if [[ "\$pid" =~ [0-9]+ ]] && kill -0 "\$pid" 2>/dev/null; then
        "\$cpulimit" -l "\$CPU_LIMIT_PERCENT" -p "\$pid" -z >/dev/null 2>&1 &
        echo "Applied CPU limit of \$CPU_LIMIT_PERCENT% to server instance #\$i (PID: \$pid)"
        break
      fi
    fi
    sleep 0.2
  done
done

# Client instance: syncs with external Stratum 1 servers, serves time to server instances on port 11123
# This instance is internal-only and listens on port 11123 for server instances to connect
# NO CPU LIMIT for the client instance (acts as interface)
"\$chronyd" "\$@" -n \\
  "include \$conf" \\
  "pidfile /var/run/chrony/chronyd-client.pid" \\
  "bindcmdaddress /var/run/chrony/chronyd-client.sock" \\
  "port 11123" "bindaddress 127.0.0.1" "sched_priority 1" "allow 127.0.0.1" &
wait
EOF
chmod +x /root/multichronyd.sh
print_success "Multi-instance script created with CPU limits and made executable."

# 10. Create the systemd Service File
print_action "Creating the multichronyd.service systemd file"
cat << 'EOF' > /etc/systemd/system/multichronyd.service
[Unit]
Description=Multi-Instance Chronyd Service Manager (Greencloud - CPU Limited)
After=network.target
[Service]
User=root
Group=root
ExecStart=/root/multichronyd.sh
Restart=always
RestartSec=10
Type=simple
[Install]
WantedBy=multi-user.target
EOF
print_success "Systemd service file created."

# 11. Start the Multi-Chrony Service
print_action "Reloading systemd and starting multichronyd.service"
systemctl daemon-reload
systemctl enable --now multichronyd.service &>>"$LOG_FILE"
if ! systemctl is-active --quiet multichronyd; then
    print_error "Failed to start multichronyd.service. Check log: $LOG_FILE"; exit 1;
fi
print_success "Multi-instance chrony service is now active."

# 12. Verify CPU limits are applied
print_action "Verifying CPU limits are applied"
sleep 3
for i in $(seq 1 $CPU_CORES); do
    if [ -f "/var/run/chrony/chronyd-server$i.pid" ]; then
        pid=$(cat "/var/run/chrony/chronyd-server$i.pid" 2>/dev/null)
        if [[ "$pid" =~ [0-9]+ ]]; then
            if pgrep -f "cpulimit.*$pid" >/dev/null 2>&1; then
                print_success "CPU limit active for server instance #$i (PID: $pid)"
            else
                print_warning "CPU limit process not found for server instance #$i (PID: $pid)"
            fi
        fi
    fi
done

# 13. Final Verification
print_action "Waiting for initial sync..."
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
print_info "CPU Limits Summary:"
print_info "  - chrony (client): No limit"
print_info "  - _chrony (server instances): 30% CPU limit each (2 instances = 60% total)"

