# 🛡️ PUBLIC NTP POOL SERVER - ALL-IN-ONE DEPLOYMENT

Production-ready bash scripts for deploying a high-performance public NTP pool server with automatic CPU core detection and SO_REUSEPORT load balancing.

---

## 📋 Two Deployment Options

### 1. **`deploy_ntp.sh`** - Full Performance (Unlimited CPU)

**Best for:** Maximum throughput, dedicated NTP servers, high-traffic pools

**Features:**
- ✅ Auto CPU detection (1 core → N cores)
- ✅ SO_REUSEPORT architecture (kernel load-balancing)
- ✅ All cores fully utilized
- ✅ 15 Stratum 1 upstream servers
- ✅ IPv4 + IPv6 support (`allow 0/0`, `allow ::/0`)
- ✅ Auto-install chrony + UFW
- ✅ Auto-detect & remove conflicting services
- ✅ sched_priority 1 (reduced packet loss)

**Deploy:**
```bash
sudo bash deploy_ntp.sh
```

---

### 2. **`deploy_ntp_limited.sh`** - CPU Limited (30% per core)

**Best for:** Shared VPS, fair usage compliance, resource constraints

**Features:**
- ✅ All features from `deploy_ntp.sh` PLUS:
- ✅ CPU limit: 30% per instance (configurable)
- ✅ For 2 cores: 60% total CPU usage
- ✅ For 4 cores: 120% total CPU usage
- ✅ Uses `cpulimit` (auto-installed)
- ✅ Respects hosting provider's fair usage policies

**Deploy:**
```bash
sudo bash deploy_ntp_limited.sh
```

**Adjust CPU limit** (edit line 42):
```bash
CPU_LIMIT_PERCENT=30  # Change this value
```

---

## 🚀 Quick Comparison

| Feature | Unlimited | Limited |
|---------|-----------|---------|
| Script | `deploy_ntp.sh` | `deploy_ntp_limited.sh` |
| CPU Usage | Full cores | 30% per core (configurable) |
| Best For | Dedicated servers | Shared VPS |
| Throughput | Maximum | Controlled |
| Fair Usage | High risk | Compliant |
| Installation | Automatic | Automatic + cpulimit |

---

## 💻 System Requirements

### Minimum
- Linux (Ubuntu, Debian, CentOS, RHEL, Fedora, Arch, Alpine)
- 1 CPU core
- 512 MB RAM
- Root/sudo access
- Internet connectivity

### Recommended
- 2+ CPU cores
- 1 GB RAM
- Public static IP
- Low-latency network

---

## 🔧 How They Work

### Architecture: SO_REUSEPORT Load Balancing

```
Incoming NTP Requests (Port 123)
            ↓
    [Kernel SO_REUSEPORT]
            ↓
    Distributes across:
    ├─ chronyd instance #1 (core 1)
    ├─ chronyd instance #2 (core 2)
    ├─ chronyd instance #3 (core 3)
    └─ chronyd instance #N (core N)
```

**Each instance:**
- ✅ Independently syncs from 15 Stratum 1 servers
- ✅ Listens on same port 123 (kernel handles distribution)
- ✅ sched_priority 1 (minimizes packet loss)
- ✅ Public access enabled (allow 0/0, ::/0)

---

## 🌍 Stratum 1 Time Sources (15 Total)

All scripts use premium global sources:

- **Google** - time.google.com (Anycast)
- **Facebook** - time.facebook.com (Anycast)
- **Apple** - time.apple.com (Anycast)
- **Netnod** - ntp.se (Anycast)
- **NICT** - ntp.nict.jp (Japan)
- **NPL** - time.nplindia.org (India)
- **NIST** - time.nist.gov (USA)
- **USASK** - tick.usask.ca (Canada)
- **PTB** - ptbtime1.ptb.de (Germany)
- **Hurricane Electric** - clock.fmt.he.net (USA)
- **LEON-TP** - ntp1.leontp.com (France)
- **CBK** - vega.cbk.poznan.pl (Poland)
- **BSN** - ntp.bsn.go.id (Indonesia)
- **NIMT** - time1.nimt.or.th (Thailand)
- **HK Observatory** - time.hko.hk (Hong Kong)

---

## 📈 What Gets Installed

✅ **chrony** - NTP daemon (auto-installed if missing)
✅ **UFW** - Firewall (auto-installed if missing, or uses firewalld)
✅ **cpulimit** - CPU limiting (auto-installed for limited version only)
✅ **systemd service** - Auto-start on boot
✅ **multichronyd.sh** - Multi-instance launcher

---

## 🔐 What Gets Cleaned Up

Before deployment, the script removes:
- ✅ systemd-timesyncd (conflicts)
- ✅ ntpd, ntp packages (conflicts)
- ✅ openntpd, ntpdate (conflicts)
- ✅ Old chrony instances (clean slate)

---

## 🔥 Firewall Configuration

Automatically configured:
- ✅ Port 123/UDP opened (NTP)
- ✅ Port 22/TCP preserved (SSH)
- ✅ UFW enabled (or firewalld configured)

---

## ✅ Verification

After deployment, verify it's working:

```bash
# Check sync status
chronyc tracking

# View active time sources
chronyc sources

# Check port listening
ss -lupn | grep :123

# View service status
systemctl status multichronyd.service

# View logs
journalctl -u multichronyd.service -f
```

---

## 📊 Example Scenarios

### Scenario 1: Dedicated 4-Core NTP Server
```bash
# Use unlimited version for max performance
sudo bash deploy_ntp.sh
```
Result: 4 instances, all cores fully utilized

### Scenario 2: Shared VPS (2 cores, fair usage policy)
```bash
# Use limited version to stay compliant
sudo bash deploy_ntp_limited.sh
```
Result: 2 instances × 30% CPU = 60% total

### Scenario 3: Single-core Budget VPS
```bash
# Works with both scripts (auto-detects)
sudo bash deploy_ntp.sh
# or
sudo bash deploy_ntp_limited.sh
```
Result: 1 instance on 1 core (unlimited or 30% limited)

### Scenario 4: Custom CPU Limit (e.g., 20%)
```bash
# Edit deploy_ntp_limited.sh line 42
nano deploy_ntp_limited.sh
# Change: CPU_LIMIT_PERCENT=20
# Then deploy:
sudo bash deploy_ntp_limited.sh
```

---

## 🛠️ Service Management

### Start/Stop/Restart
```bash
systemctl start multichronyd.service
systemctl stop multichronyd.service
systemctl restart multichronyd.service
systemctl status multichronyd.service
```

### View Logs
```bash
journalctl -u multichronyd.service -f
tail -f /var/log/ntp_pool_setup.log
```

---

## 📋 Configuration Files

- **Chrony config:** `/etc/chrony/chrony.conf`
- **Launcher script:** `/root/multichronyd.sh`
- **Systemd service:** `/etc/systemd/system/multichronyd.service`
- **Setup log:** `/var/log/ntp_pool_setup.log`

---

## 🎯 Next Steps (Optional)

1. **Join NTP Pool Project:**
   - Register at https://www.ntppool.org/
   - Add your server's public IP
   - Earn recognition as public time server

2. **Monitor Performance:**
   ```bash
   watch -n 1 'chronyc sources'
   ```

3. **Tune for Your Network:**
   - Edit `/etc/chrony/chrony.conf`
   - Adjust polling intervals
   - Restart service

---

## 🆘 Troubleshooting

### Port 123 not listening
```bash
systemctl status multichronyd.service
journalctl -u multichronyd.service -n 50
```

### Poor time sync
```bash
chronyc sources      # Check active sources
chronyc sourcestats  # Detailed statistics
```

### High CPU usage (unlimited version)
This is normal - it's using all available cores. For less usage, switch to limited version:
```bash
sudo bash deploy_ntp_limited.sh
```

### CPU limit not working (limited version)
Verify cpulimit is installed:
```bash
which cpulimit
cpulimit --version
```

---

## 📚 References

- **Chrony Docs:** https://chrony.tuxfamily.org/
- **NTP Pool Project:** https://www.ntppool.org/
- **UFW Guide:** https://help.ubuntu.com/community/UFW
- **SO_REUSEPORT:** https://lwn.net/Articles/542629/

---

## 📄 License

Educational and production use. Modify as needed for your infrastructure.

---

## 🎉 Summary

| Task | Command |
|------|---------|
| **Deploy (Full)** | `sudo bash deploy_ntp.sh` |
| **Deploy (Limited)** | `sudo bash deploy_ntp_limited.sh` |
| **Check Status** | `chronyc tracking` |
| **View Sources** | `chronyc sources` |
| **View Logs** | `journalctl -u multichronyd.service -f` |
| **Restart Service** | `systemctl restart multichronyd.service` |

**Your public NTP pool server is just one command away!** 🚀
