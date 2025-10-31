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
print_info "Starting GreenCloud Multi-Instance Chrony with CPU Limiting & Firewall Setup"

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

# 4. Install Chrony and cpulimit
if ! command -v chronyd &>/dev/null; then
    print_action "Installing chrony"
    case "$PACKAGE_MANAGER" in
        apt) apt-get update -y && apt-get install -y chrony cpulimit &>>"$LOG_FILE";;
        dnf|yum) dnf install -y chrony cpulimit &>>"$LOG_FILE";;
        pacman) pacman -S --noconfirm chrony cpulimit &>>"$LOG_FILE";;
        apk) apk add chrony cpulimit &>>"$LOG_FILE";;
    esac
    if ! command -v chronyd &>/dev/null; then print_error "Chrony installation failed. Check log: $LOG_FILE"; exit 1; fi
    print_success "Chrony and cpulimit have been installed."
else
    print_success "Chrony is already installed. Installing cpulimit..."
    case "$PACKAGE_MANAGER" in
        apt) apt-get install -y cpulimit &>>"$LOG_FILE";;
        dnf|yum) dnf install -y cpulimit &>>"$LOG_FILE";;
        pacman) pacman -S --noconfirm cpulimit &>>"$LOG_FILE";;
        apk) apk add cpulimit &>>"$LOG_FILE";;
    esac
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


# 6. CPU Core and CPU Limiting Configuration (GreenCloud-Specific)
print_action "Configuring CPU core usage and limits (GreenCloud Mode)"
TOTAL_CORES=$(nproc)
print_info "Total CPU cores detected: $TOTAL_CORES"
print_info "GreenCloud Configuration:"
print_info "  - 1 Server instance (no CPU limit)"
print_info "  - 2 Client instances (30% CPU each = 60% total)"

# Calculate CPU limit percentage per client
CLIENT_CPU_LIMIT=30
NUM_CLIENTS=2
NUM_SERVERS=1

print_success "CPU Limiting configured:"
print_success "  - Servers: unlimited"
print_success "  - Clients: $CLIENT_CPU_LIMIT% per instance (total: $((CLIENT_CPU_LIMIT * NUM_CLIENTS))%)"

# 7. Create the Main chrony.conf with Stratum 1 Sources
CHRONY_CONF="/etc/chrony/chrony.conf"
mkdir -p "$(dirname "$CHRONY_CONF")"
print_action "Creating main configuration at $CHRONY_CONF with comprehensive Stratum 1 servers"
cat << EOF > "$CHRONY_CONF"
# This file is managed by the GreenCloud multichrony setup script.
$(for server in "${STRATUM_1_SERVERS[@]}"; do echo "server $server iburst"; done)
driftfile /var/lib/chrony/chrony.drift
allow
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
print_success "Main configuration file created."

# 8. Create the multichronyd.sh Script with CPU limiting
print_action "Generating the /root/multichronyd.sh script with CPU limiting"
cat << EOF > /root/multichronyd.sh
#!/bin/bash

servers=$NUM_SERVERS
clients=$NUM_CLIENTS
client_cpu_limit=$CLIENT_CPU_LIMIT

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
if command -v cpulimit >/dev/null 2>&1; then
    cpulimit=\$(command -v cpulimit)
else
    echo "Warning: cpulimit not found, running without CPU limits"
    cpulimit=""
fi

trap terminate SIGINT SIGTERM
terminate() {
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
# They get time from the client instances on port 11123
# Server instances have NO CPU limit
for i in \$(seq 1 "\$servers"); do
  "\$chronyd" "\$@" -n -x \\
    "server 127.0.0.1 port 11123 minpoll 0 maxpoll 0 \$opts" \\
    "allow" "cmdport 0" \\
    "bindcmdaddress /var/run/chrony/chronyd-server\$i.sock" \\
    "pidfile /var/run/chrony/chronyd-server\$i.pid" &
done

# Client instances: sync with external Stratum 1 servers, serve time to server instances on port 11123
# Client instances are rate-limited by cpulimit
for i in \$(seq 1 "\$clients"); do
  if [ -n "\$cpulimit" ]; then
    # Run with CPU limit (percentage-based)
    "\$cpulimit" -p \$\$ -l "\$client_cpu_limit" -b \\
      "\$chronyd" "\$@" -n \\
      "include \$conf" \\
      "pidfile /var/run/chrony/chronyd-client\$i.pid" \\
      "bindcmdaddress /var/run/chrony/chronyd-client\$i.sock" \\
      "port \$((11123 + i - 1))" "bindaddress 127.0.0.1" "sched_priority 1" "allow 127.0.0.1" &
  else
    # Run without CPU limit if cpulimit not available
    "\$chronyd" "\$@" -n \\
      "include \$conf" \\
      "pidfile /var/run/chrony/chronyd-client\$i.pid" \\
      "bindcmdaddress /var/run/chrony/chronyd-client\$i.sock" \\
      "port \$((11123 + i - 1))" "bindaddress 127.0.0.1" "sched_priority 1" "allow 127.0.0.1" &
  fi
done

wait
EOF
chmod +x /root/multichronyd.sh
print_success "Multi-instance script with CPU limiting created and made executable."

# 9. Create the systemd Service File
print_action "Creating the multichronyd.service systemd file"
cat << 'EOF' > /etc/systemd/system/multichronyd.service
[Unit]
Description=GreenCloud Multi-Instance Chronyd Service with CPU Limiting
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
sleep 60
print_info "Final Sync Status (chronyc tracking):"
chronyc -h /var/run/chrony/chronyd-client1.sock tracking | tee -a "$LOG_FILE"
print_info "Active Time Sources (chronyc sources):"
chronyc -h /var/run/chrony/chronyd-client1.sock sources | tee -a "$LOG_FILE"

if ss -lupn | grep -q ":123"; then
    print_success "${SERVER_EMOJI} NTP service is up and listening on port 123."
else
    print_warning "NTP service is not listening on port 123. It may be in client-only mode or blocked."
fi

print_info "GreenCloud Setup complete!"
print_info "CPU Limiting active: 2 clients @ 30% each, 1 server unlimited"
