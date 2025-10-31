#!/bin/bash

# This script performs a one-time setup (install, firewall) and then
# launches a multi-instance chrony environment.
# - 'nproc' client instances are started for local benchmarking.
# - One main instance is started to:
#   1. Serve time to the public on port 123 (synced from Stratum 1s).
#   2. Serve time to the local clients on port 11123.
#
# It MUST be run with sudo or as root.

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
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
# --- End Configuration ---

# Step 0: Check for Root Privileges
if [ "$EUID" -ne 0 ]; then
  echo "❌ Error: This script must be run as root. Please use sudo."
  exit 1
fi

# --- Step 1: Install Chrony ---
echo "⚙️  Installing chrony..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install chrony -y
elif command -v dnf &> /dev/null; then
    sudo dnf install chrony -y
elif command -v yum &> /dev/null; then
    sudo yum install chrony -y
else
    echo "❌ Error: Could not find 'apt-get', 'dnf', or 'yum'."
    exit 1
fi

# --- Step 2: Configure Firewall ---
echo "🔥 Configuring firewall..."
if command -v firewall-cmd &> /dev/null; then
    sudo systemctl start firewalld
    sudo systemctl enable firewalld
    sudo firewall-cmd --add-service=ssh --permanent
    sudo firewall-cmd --add-service=ntp --permanent # 123/udp
    sudo firewall-cmd --reload
elif command -v ufw &> /dev/null; then
    sudo ufw allow ssh
    sudo ufw allow 123/udp # 'ntp'
    sudo ufw --force enable
else
    # Silently skip if no firewall manager is found
    :
fi

# --- Step 3: Stop System Service ---
# We are running chronyd manually, so disable the system service.
echo "🧹 Stopping and disabling system chrony service..."
SERVICE_NAME="chrony"
if systemctl list-unit-files | grep -q 'chronyd.service'; then
    SERVICE_NAME="chronyd"
fi
sudo systemctl stop "$SERVICE_NAME" || true
sudo systemctl disable "$SERVICE_NAME" || true

# --- Step 4: Multi-Instance Chrony Setup ---
servers=$(nproc)
chronyd="/usr/sbin/chronyd"

trap terminate SIGINT SIGTERM

terminate()
{
	for p in /var/run/chrony/chronyd*.pid; do
		pid=$(cat "$p" 2> /dev/null)
		[[ "$pid" =~ [0-9]+ ]] && kill "$pid"
	done
}

# Check chrony version for extended features
case "$("$chronyd" --version | grep -o -E '[1-9]\.[0-9]+')" in
	1.*|2.*|3.*)
		echo "chrony version too old to run multiple instances"
		exit 1;;
	4.0)	opts="";;
	4.1)	opts="xleave copy";;
	*)	opts="xleave copy extfield F323";;
esac

# Start the 'nproc' client instances for benchmarking
for i in $(seq 1 "$servers"); do
	"$chronyd" "$@" -n -x \
		"sched_priority 1" \
		"server 127.0.0.1 port 11123 minpoll 0 maxpoll 0 $opts" \
	       	"allow" \
	       	"cmdport 0" \
	       	"bindcmdaddress /var/run/chrony/chronyd-client$i.sock" \
	       	"pidfile /var/run/chrony/chronyd-client$i.pid" &
done

# --- Main Public/Internal Server Instance ---
echo "🚀 Starting main server (Public @ Port 123, Internal @ Port 11123)..."

# Build the config arguments in an array
declare -a main_server_args
main_server_args+=(
    "sched_priority 1"
    "driftfile /var/lib/chrony/drift"
    "makestep 1.0 3"
    "rtcsync"
    "logdir /var/log/chrony"
    "log measurements statistics tracking"
    "local stratum 10"
    "cmdallow 127.0.0.1"
    "port 123"    # Public port, binds to 0.0.0.0
    "port 11123"  # Internal test port, binds to 0.0.0.0
    "allow 0/0"   # Allow all clients on all ports
)

# Add all the upstream servers
for server in "${STRATUM_1_SERVERS[@]}"; do
    main_server_args+=("server $server iburst")
done

# Launch the main server
"$chronyd" "$@" -n "${main_server_args[@]}" &

wait