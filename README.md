# ntp-scripts
All ntp scripts for hosting NTP Pool Server would be here

### Universal Multi-Chrony & Firewall Setup Script

A powerful, one-line command to set up a secure, high-performance, and globally optimized NTP server on almost any Linux system.

---

#### ✨ Key Features

* 🌐 **Universal Compatibility**: Auto-detects your OS (Debian, Ubuntu, Arch, Fedora, etc.) and package manager.
* 🚀 **High-Performance**: Deploys a multi-instance `chrony` setup that scales with your CPU cores for maximum performance.
* 🔒 **Automated Security**: Installs, enables, and configures a UFW firewall, ensuring your server is secure while allowing necessary NTP & SSH traffic.
* 🎯 **Precision Time**: Pre-configured with a curated list of the world's best Stratum 1 NTP servers, optimized for global and regional performance.
* 🤝 **NTP Pool Ready**: Includes the necessary configuration to be a public server for the [NTP Pool Project](https://www.ntppool.org/).
* 🤖 **Fully Automatic**: Resolves conflicts with other time services and configures itself to serve time to your local network.

---

#### 🚀 How to Use
run commands
```
git clone https://github.com/ShayNeeo/ntp-scripts.git
cd ntp-scripts
./install_multichronyd_universal.sh
```

The script will guide you through a single question (how many CPU cores to use) and handle the rest automatically.

---

#### ✅ The Result

The script leaves you with a robust, secure, and highly accurate NTP server, ready for professional use or contributing to the global NTP Pool Project.
