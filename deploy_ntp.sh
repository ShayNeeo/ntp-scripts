#!/bin/bash

################################################################################
# PUBLIC NTP POOL SERVER - ALL-IN-ONE DEPLOYMENT SCRIPT
# SO_REUSEPORT approach: Multiple instances on port 123 for optimal throughput
# Auto-detects CPU cores, installs chrony + UFW, cleans conflicting services
################################################################################

set -e

# ANSI Colors & Emojis
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; CYAN="\033[0;36m"; RESET="\033[0m"
CHECK="✅"; ERROR="❌"; INFO="ℹ️"; SYNC="🔄"; SERVER="🛡️"; FIRE="🔥"; CORE="⚙️"

LOG_FILE="/var/log/ntp_pool_setup.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/ntp_pool_setup.log"

print_info() { echo -e "${BLUE}${INFO} $1${RESET}" | tee -a "$LOG_FILE"; }
print_success() { echo -e "${GREEN}${CHECK} $1${RESET}" | tee -a "$LOG_FILE"; }
print_error() { echo -e "${RED}${ERROR} $1${RESET}" | tee -a "$LOG_FILE"; }
print_action() { echo -e "${CYAN}${SYNC} $1...${RESET}" | tee -a "$LOG_FILE"; }
print_header() { echo -e "\n${BLUE}════════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"; echo -e "${BLUE}$1${RESET}" | tee -a "$LOG_FILE"; echo -e "${BLUE}════════════════════════════════════════════════════════${RESET}\n" | tee -a "$LOG_FILE"; }

# Stratum 1 NTP Servers
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

echo "=== Deployment started $(date) ===" >> "$LOG_FILE"
print_header "PUBLIC NTP POOL SERVER - SO_REUSEPORT DEPLOYMENT"

# 1. Root check
[[ $EUID -ne 0 ]] && { print_error "Must run as root"; exit 1; }
print_success "Running as root"

# 2. Detect OS
print_action "Detecting OS and package manager"
[ -f /etc/os-release ] && . /etc/os-release
DISTRO=${NAME:-"Unknown"}
PACKAGE_MANAGER=""

for pm in apt dnf yum pacman apk; do
    command -v "$pm" &>/dev/null && { PACKAGE_MANAGER="$pm"; break; }
done

[[ -z "$PACKAGE_MANAGER" ]] && { print_error "No package manager found"; exit 1; }
print_success "System: $DISTRO | Package Manager: $PACKAGE_MANAGER"

# 3. CPU Detection
print_action "Detecting CPU cores"
TOTAL_CORES=$(nproc)
print_info "Total CPU cores: ${CORE} $TOTAL_CORES"

if [ "$TOTAL_CORES" -gt 1 ]; then
    print_success "Multi-core system → Using SO_REUSEPORT (all cores on port 123)"
else
    print_success "Single-core system → Single chrony instance"
fi

# 4. Cleanup conflicting services
print_header "CLEANING UP CONFLICTING SERVICES"
for service in systemd-timesyncd ntpd chrony chronyd multichronyd openntpd ntp; do
    systemctl disable --now "$service" 2>/dev/null && print_info "Disabled: $service"
done

case "$PACKAGE_MANAGER" in
    apt) apt-get remove -y ntp openntpd ntpdate 2>/dev/null && print_info "Removed legacy NTP packages" ;;
    dnf|yum) dnf remove -y ntp openntpd ntpdate 2>/dev/null && print_info "Removed legacy NTP packages" ;;
esac
print_success "Cleanup complete"

# 5. Install chrony
print_header "INSTALLING CHRONY"
if ! command -v chronyd &>/dev/null; then
    print_action "Installing chrony package"
    case "$PACKAGE_MANAGER" in
        apt) apt-get update -y && apt-get install -y chrony ;;
        dnf|yum) dnf install -y chrony ;;
        pacman) pacman -S --noconfirm chrony ;;
        apk) apk add chrony ;;
    esac &>>"$LOG_FILE"
    command -v chronyd &>/dev/null || { print_error "Chrony install failed"; exit 1; }
    print_success "Chrony installed"
else
    print_success "Chrony already installed"
fi

# 6. Firewall setup
print_header "FIREWALL CONFIGURATION ${FIRE}"
if systemctl is-active --quiet firewalld; then
    print_success "firewalld detected - configuring"
    firewall-cmd --permanent --add-port=123/udp &>>"$LOG_FILE"
    firewall-cmd --reload &>>"$LOG_FILE"
    print_success "Opened port 123/udp"
else
    if ! command -v ufw &>/dev/null; then
        print_action "Installing UFW"
        case "$PACKAGE_MANAGER" in
            apt) apt-get install -y ufw ;;
            dnf|yum) dnf install -y ufw ;;
            pacman) pacman -S --noconfirm ufw ;;
            *) print_info "UFW auto-install not available for this OS" ;;
        esac &>>"$LOG_FILE"
    fi
    
    if command -v ufw &>/dev/null; then
        ufw allow ssh &>>"$LOG_FILE"
        ufw allow 123/udp &>>"$LOG_FILE"
        echo "y" | ufw enable &>>"$LOG_FILE" 2>/dev/null
        print_success "UFW configured and enabled"
    fi
fi

# 7. Create chrony.conf
print_header "CREATING CHRONY CONFIGURATION"
CHRONY_CONF="/etc/chrony/chrony.conf"
mkdir -p "$(dirname "$CHRONY_CONF")"
print_action "Generating $CHRONY_CONF"

cat > "$CHRONY_CONF" << 'CONF'
# Chrony Configuration - SO_REUSEPORT Public NTP Pool Server

# --- Upstream Stratum 1 Servers ---
CONF

for server in "${STRATUM_1_SERVERS[@]}"; do
    echo "server $server iburst" >> "$CHRONY_CONF"
done

cat >> "$CHRONY_CONF" << 'CONF'

# --- Core Settings ---
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
log measurements statistics tracking

# --- Public Server Settings ---
allow 0/0
local stratum 10

# --- Performance Tuning ---
hwtimestamp *
correctiontime 1.0 2.0
CONF

print_success "Chrony configuration created"

# 8. Create multichronyd launcher (SO_REUSEPORT approach)
print_header "DEPLOYING MULTICHRONY - SO_REUSEPORT (${TOTAL_CORES} instances)"
print_action "Creating /root/multichronyd.sh launcher"

cat > /root/multichronyd.sh << 'LAUNCHER'
#!/bin/bash

servers=$(nproc)
chronyd="/usr/sbin/chronyd"
conf="/etc/chrony/chrony.conf"

trap terminate SIGINT SIGTERM
terminate()
{
	for p in /var/run/chrony/chronyd*.pid; do
		pid=$(cat "$p" 2>/dev/null)
		[[ "$pid" =~ [0-9]+ ]] && kill "$pid" 2>/dev/null
	done
}

case "$("$chronyd" --version | grep -o -E '[1-9]\.[0-9]+')" in
	1.*|2.*|3.*)
		echo "chrony version too old (needs 4.0+)"
		exit 1;;
	4.0)	opts="";;
	4.1)	opts="xleave copy";;
	*)	opts="xleave copy extfield F323";;
esac

mkdir -p /var/run/chrony

# SO_REUSEPORT: All instances listen on same port 123
# Kernel distributes incoming NTP requests across all instances
# Each instance independently syncs from upstream Stratum 1 servers

for i in $(seq 1 "$servers"); do
	echo "Starting NTP instance #$i on port 123 (core $i)" >&2
	"$chronyd" "$@" -n \
		"include $conf" \
		"port 123" \
		"allow 0/0" \
		"sched_priority 1" \
		"local stratum 10" \
		"cmdport 0" \
		"bindcmdaddress /var/run/chrony/chronyd-$i.sock" \
		"pidfile /var/run/chrony/chronyd-$i.pid" &
done

wait
echo "All instances exited" >&2
LAUNCHER

chmod +x /root/multichronyd.sh
print_success "Launcher script created"

# 9. Create systemd service
print_action "Creating systemd service"
cat > /etc/systemd/system/multichronyd.service << 'SERVICE'
[Unit]
Description=Multi-Instance Chronyd (SO_REUSEPORT) - Public NTP Pool
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
Type=notify
ExecStart=/root/multichronyd.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

print_success "Systemd service created"

# 10. Start service
print_action "Starting multichronyd service"
systemctl daemon-reload
systemctl enable multichronyd.service
systemctl start multichronyd.service

sleep 2
if systemctl is-active --quiet multichronyd.service; then
    print_success "Multichronyd service running"
else
    print_error "Service failed to start"
    systemctl status multichronyd.service | tee -a "$LOG_FILE"
    exit 1
fi

# 11. Verify
print_header "VERIFICATION & STATUS"
print_action "Waiting 60 seconds for time sync..."
sleep 60

print_info "Checking first instance status:"
chronyc -h /var/run/chrony/chronyd-1.sock tracking 2>/dev/null | tee -a "$LOG_FILE"

print_info "Active time sources:"
chronyc -h /var/run/chrony/chronyd-1.sock sources 2>/dev/null | tee -a "$LOG_FILE"

print_info "Number of listening NTP instances:"
ss -lupn 2>/dev/null | grep -c ":123 " || echo "0"

if ss -lupn 2>/dev/null | grep -q ":123 "; then
    print_success "${SERVER} NTP Server ACTIVE on port 123/UDP (${TOTAL_CORES} instances)"
else
    print_error "Port 123 not listening"
fi

# 12. Summary
print_header "DEPLOYMENT SUMMARY"
print_info "CPU Cores: $TOTAL_CORES"
print_info "Deployment: SO_REUSEPORT (all cores on port 123)"
print_info "Upstream Servers: ${#STRATUM_1_SERVERS[@]} Stratum 1 sources"
print_info "Public Access: ALLOWED (0/0)"
print_info "Firewall: UFW/firewalld (port 123/UDP open)"
print_info "Scheduler Priority: 1 (reduced packet loss)"
print_info "Log: $LOG_FILE"
print_success "Public NTP Pool Server ready!"
