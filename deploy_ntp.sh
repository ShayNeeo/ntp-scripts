#!/bin/bash

################################################################################
# PUBLIC NTP POOL SERVER - ALL-IN-ONE DEPLOYMENT SCRIPT
# SO_REUSEPORT approach: Multiple instances on port 123 for optimal throughput
# Auto-detects CPU cores, installs chrony + UFW, cleans conflicting services
################################################################################

set -euo pipefail

# ANSI Colors & Emojis
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; CYAN="\033[0;36m"; RESET="\033[0m"
CHECK="✅"; ERROR="❌"; INFO="ℹ️"; SYNC="🔄"; SERVER="🛡️"; FIRE="🔥"; CORE="⚙️"

LOG_FILE="/var/log/ntp_pool_setup.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/ntp_pool_setup.log"
fi

print_info() { echo -e "${BLUE}${INFO} $1${RESET}" | tee -a "$LOG_FILE"; }
print_success() { echo -e "${GREEN}${CHECK} $1${RESET}" | tee -a "$LOG_FILE"; }
print_error() { echo -e "${RED}${ERROR} $1${RESET}" | tee -a "$LOG_FILE"; }
print_action() { echo -e "${CYAN}${SYNC} $1...${RESET}" | tee -a "$LOG_FILE"; }
print_header() { echo -e "\n${BLUE}════════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"; echo -e "${BLUE}$1${RESET}" | tee -a "$LOG_FILE"; echo -e "${BLUE}════════════════════════════════════════════════════════${RESET}\n" | tee -a "$LOG_FILE"; }

# Stratum 1 NTP Servers
STRATUM_1_SERVERS=(
    "time.google.com"
    "time.apple.com"
    "ntp.nict.jp"
    "time.nplindia.org"
    "time1.nimt.or.th"
    "time.hko.hk"
)

echo "=== Deployment started $(date) ===" >> "$LOG_FILE"
print_header "PUBLIC NTP POOL SERVER - SO_REUSEPORT DEPLOYMENT"
print_info "Log file: $LOG_FILE"

# 0. Pre-flight checks
print_header "PRE-FLIGHT CHECKS"
print_action "Verifying required commands"
for cmd in nproc systemctl ss chronyc; do
    command -v "$cmd" &>/dev/null || { print_error "Required command not found: $cmd"; exit 1; }
done
print_success "All required commands available"

# 1. Root check
[[ $EUID -ne 0 ]] && { print_error "Must run as root"; exit 1; }
print_success "Running as root"

# 2. Detect OS
print_action "Detecting OS and package manager"
[ -f /etc/os-release ] && . /etc/os-release || true
DISTRO=${NAME:-"Unknown"}
PACKAGE_MANAGER=""

for pm in apt dnf yum pacman apk; do
    command -v "$pm" &>/dev/null && { PACKAGE_MANAGER="$pm"; break; } || true
done

[[ -z "$PACKAGE_MANAGER" ]] && { print_error "No package manager found"; exit 1; }
print_success "System: $DISTRO | Package Manager: $PACKAGE_MANAGER"

# 3. CPU Detection
print_action "Detecting CPU cores"
TOTAL_CORES=$(nproc 2>/dev/null) || { print_error "Failed to detect CPU cores"; exit 1; }
[ "$TOTAL_CORES" -gt 0 ] 2>/dev/null || { print_error "Invalid CPU count: $TOTAL_CORES"; exit 1; }
print_info "Total CPU cores: ${CORE} $TOTAL_CORES"

if [ "$TOTAL_CORES" -gt 1 ]; then
    print_success "Multi-core system → Using SO_REUSEPORT (all cores on port 123)"
else
    print_success "Single-core system → Single chrony instance"
fi

# 4. Cleanup conflicting services
print_header "CLEANING UP CONFLICTING SERVICES"
for service in systemd-timesyncd ntpd chrony chronyd multichronyd openntpd ntp; do
    systemctl disable --now "$service" 2>/dev/null && print_info "Disabled: $service" || true
done

case "$PACKAGE_MANAGER" in
    apt) apt-get remove -y ntp openntpd ntpdate 2>/dev/null && print_info "Removed legacy NTP packages" || true ;;
    dnf|yum) dnf remove -y ntp openntpd ntpdate 2>/dev/null && print_info "Removed legacy NTP packages" || true ;;
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
    esac &>>"$LOG_FILE" || { print_error "Chrony installation failed"; exit 1; }
    command -v chronyd &>/dev/null || { print_error "Chrony install failed"; exit 1; }
    print_success "Chrony installed"
else
    print_success "Chrony already installed"
fi

# Detect chronyd path
CHRONYD=$(command -v chronyd) || { print_error "chronyd not found in PATH"; exit 1; }
print_info "Using chronyd: $CHRONYD"

# 6. Firewall setup
print_header "FIREWALL CONFIGURATION ${FIRE}"
if systemctl is-active --quiet firewalld 2>/dev/null; then
    print_success "firewalld detected - configuring"
    firewall-cmd --permanent --add-port=123/udp &>>"$LOG_FILE" || true
    firewall-cmd --reload &>>"$LOG_FILE" || true
    print_success "Opened port 123/udp on firewalld"
else
    if ! command -v ufw &>/dev/null; then
        print_action "Installing UFW"
        case "$PACKAGE_MANAGER" in
            apt) apt-get install -y ufw ;;
            dnf|yum) dnf install -y ufw ;;
            pacman) pacman -S --noconfirm ufw ;;
            *) print_info "UFW auto-install not available for this OS" ;;
        esac &>>"$LOG_FILE" || true
    fi
    
    if command -v ufw &>/dev/null; then
        ufw allow ssh &>>"$LOG_FILE" || true
        ufw allow 123/udp &>>"$LOG_FILE" || true
        echo "y" | ufw enable &>>"$LOG_FILE" 2>/dev/null || print_info "UFW already enabled"
        print_success "UFW configured and enabled"
    fi
fi

# 7. Create chrony.conf
print_header "CREATING CHRONY CONFIGURATION"
CHRONY_CONF="/etc/chrony/chrony.conf"
mkdir -p "$(dirname "$CHRONY_CONF")"
print_action "Generating $CHRONY_CONF"

cat > "$CHRONY_CONF" << 'CONF' || { print_error "Failed to write chrony.conf header"; exit 1; }
# Chrony Configuration - SO_REUSEPORT Public NTP Pool Server

# --- Upstream Stratum 1 Servers ---
CONF

for server in "${STRATUM_1_SERVERS[@]}"; do
    echo "server $server iburst" >> "$CHRONY_CONF" || { print_error "Failed to write server entry: $server"; exit 1; }
done

cat >> "$CHRONY_CONF" << 'CONF' || { print_error "Failed to write chrony.conf footer"; exit 1; }

# --- Core Settings ---
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
log measurements statistics tracking

# --- Public Server Settings ---
allow 0/0
allow ::/0
local stratum 10

# --- Performance Tuning ---
hwtimestamp *
CONF

print_success "Chrony configuration created"

# 8. Create multichronyd launcher (SO_REUSEPORT approach)
print_header "DEPLOYING MULTICHRONY - SO_REUSEPORT (${TOTAL_CORES} instances)"
print_action "Creating /root/multichronyd.sh launcher"

# Fix permissions for /var/run/chrony
mkdir -p /var/run/chrony
chmod 770 /var/run/chrony
# Find the chronyd user and set ownership - improved regex
CHRONY_USER=$(getent passwd 2>/dev/null | grep -E '^(_?chrony(d)?):' | cut -d: -f1 | head -1 || true)
if [ -n "$CHRONY_USER" ]; then
    chown "$CHRONY_USER:$CHRONY_USER" /var/run/chrony
    print_info "Set /var/run/chrony ownership to $CHRONY_USER"
else
    chown root:root /var/run/chrony
    print_info "Using root ownership for /var/run/chrony (chronyd user not found)"
fi

cat > /root/multichronyd.sh << 'LAUNCHER' || { print_error "Failed to create launcher script"; exit 1; }
#!/bin/bash
set -euo pipefail

# Startup delay to allow network to be ready
sleep 2

servers=$(nproc)
chronyd="CHRONYD_PATH"
conf="/etc/chrony/chrony.conf"

trap terminate SIGINT SIGTERM EXIT
terminate()
{
	for p in /var/run/chrony/chronyd*.pid; do
		pid=$(cat "$p" 2>/dev/null || true)
		[[ "$pid" =~ [0-9]+ ]] && kill "$pid" 2>/dev/null || true
	done
	exit 0
}

# Validate prerequisites
if [ ! -f "$conf" ]; then
	echo "ERROR: Chrony configuration not found: $conf" >&2
	exit 1
fi

if [ ! -x "$chronyd" ]; then
	echo "ERROR: chronyd not executable: $chronyd" >&2
	exit 1
fi

case "$("$chronyd" --version 2>/dev/null | grep -o -E '[1-9]\.[0-9]' | head -1)" in
	1.*|2.*|3.*)
		echo "ERROR: chrony version too old (needs 4.0+)" >&2
		exit 1;;
	4.0)	opts="";;
	4.1)	opts="xleave copy";;
	*)	opts="xleave copy extfield F323";;
esac

mkdir -p /var/run/chrony
chmod 770 /var/run/chrony

# SO_REUSEPORT: All instances listen on same port 123
# Kernel distributes incoming NTP requests across all instances
# Each instance independently syncs from upstream Stratum 1 servers

for i in $(seq 1 "$servers"); do
	echo "Starting NTP instance #$i on port 123 (core $i)" >&2
	"$chronyd" "$@" -n \
		"include $conf" \
		"port 123" \
		"allow 0/0" \
		"allow ::/0" \
		"sched_priority 1" \
		"local stratum 10" \
		"cmdport 0" \
		"pidfile /var/run/chrony/chronyd-$i.pid" &
done

wait
echo "All instances exited" >&2
LAUNCHER

# Replace path placeholder in launcher
sed -i "s|CHRONYD_PATH|$CHRONYD|g" /root/multichronyd.sh
chmod +x /root/multichronyd.sh
print_success "Launcher script created"

# 9. Create systemd service
print_action "Creating systemd service"
cat > /etc/systemd/system/multichronyd.service << 'SERVICE' || { print_error "Failed to create systemd service"; exit 1; }
[Unit]
Description=Multi-Instance Chronyd (SO_REUSEPORT) - Public NTP Pool
Documentation=https://chrony.tuxfamily.org/
After=network-online.target
Wants=network-online.target
Before=systemd-user-sessions.service

[Service]
User=root
Group=root
Type=simple
ExecStartPre=/bin/mkdir -p /var/run/chrony
ExecStart=/root/multichronyd.sh
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=5
TimeoutStartSec=60
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
StandardInput=null
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
    systemctl status multichronyd.service | tee -a "$LOG_FILE" || true
    exit 1
fi

# 11. Verify
print_header "VERIFICATION & STATUS"
print_action "Waiting 10 seconds for time sync..."
sleep 10

print_info "Checking first instance status:"
chronyc sources 2>/dev/null | tee -a "$LOG_FILE" || print_warning "chronyc not yet responding (syncing...)"

print_info "Active time sources:"
chronyc tracking 2>/dev/null | tee -a "$LOG_FILE" || print_warning "chronyc not yet responding (syncing...)"

print_info "Number of listening NTP instances:"
INSTANCE_COUNT=$(ss -lupn 2>/dev/null | grep -c ":123 " || echo "0")
echo "$INSTANCE_COUNT"

if ss -lupn 2>/dev/null | grep -q ":123 "; then
    print_success "${SERVER} NTP Server ACTIVE on port 123/UDP (${TOTAL_CORES} instances)"
else
    print_error "Port 123 not listening"
fi

# 12. Summary
print_header "DEPLOYMENT SUMMARY"
print_info "CPU Cores: $TOTAL_CORES"
print_info "Deployment Mode: SO_REUSEPORT (all cores on port 123)"
print_info "Upstream Servers: ${#STRATUM_1_SERVERS[@]} Stratum 1 sources"
print_info "Public Access: ALLOWED (IPv4: 0/0, IPv6: ::/0)"
print_info "Firewall: UFW/firewalld (port 123/UDP open)"
print_info "Scheduler Priority: 1 (reduced packet loss)"
print_info "Chronyd Path: $CHRONYD"
print_info "Launcher: /root/multichronyd.sh"
print_info "Service: /etc/systemd/system/multichronyd.service"
print_info "Log File: $LOG_FILE"
print_success "Public NTP Pool Server ready!"
