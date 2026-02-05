# PVE Installer

Automated Proxmox VE installation with Claude Code CLI integration.

## What This Does

1. Creates a bootable USB with Proxmox VE installer
2. After PVE installation, sets up Claude Code for AI-assisted server management
3. Claude helps you configure networking, create VMs, set up backups, etc.

## Quick Start (Windows 11)

### 1. Clone the Repository

```powershell
git clone https://github.com/serenity-its-development/pve-installer.git
cd pve-installer
```

### 2. Create Bootable USB

Run PowerShell as Administrator:

```powershell
cd build
.\Create-BootableUSB.ps1
```

This will:
- Detect your USB drive
- Download Proxmox VE ISO (~1.2 GB)
- Format and prepare the USB
- Copy all necessary files

### 3. Install Proxmox

1. **Boot** your server from the USB
2. **Select** "Install Proxmox VE (Graphical)"
3. **Follow** the installer prompts
4. **Reboot** when complete

### 4. First Boot (Automatic!)

After Proxmox reboots, **Claude setup runs automatically!**

**At the console** (keyboard + monitor on server):
```
Login: root
Password: <your password>

Type: tm
```

**Or via SSH:**
```bash
ssh root@<your-server-ip>
tm
```

That's it - Claude is ready!

> **If auto-setup didn't run**, trigger it manually:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/serenity-its-development/pve-installer/main/post-install/first-boot-setup.sh | bash
> ```

### 5. Use Claude

Attach to the Claude session:

```bash
tmux attach -t claude
# Or use the alias:
tm
```

Example commands:
```
> Set static IP 192.168.1.100/24 with gateway 192.168.1.1 and DNS 8.8.8.8
> Create a new VM with Ubuntu 24.04, 4 cores, 8GB RAM, 100GB disk
> Set up daily backups for all VMs at 2am
> Show me the status of all storage pools
```

## Requirements

### Build System (Windows)
- Windows 10/11
- PowerShell (Run as Administrator)
- USB drive (8GB+ recommended)
- Internet connection

### Target Server
- x86_64 system with UEFI or Legacy BIOS
- Minimum 4GB RAM (8GB+ recommended)
- Network connectivity (DHCP)
- Storage drive(s) for Proxmox

## Project Structure

```
pve-installer/
├── build/
│   └── Create-BootableUSB.ps1   # Windows USB creator
├── installer/
│   ├── install-proxmox.sh       # Manual PVE installation
│   ├── configure-zfs.sh         # ZFS pool setup
│   └── configure-network.sh     # Network utilities
├── post-install/
│   ├── first-boot-setup.sh      # Run after PVE install ← Start here!
│   ├── setup-claude.sh          # Claude Code installer
│   └── configure-static-ip.sh   # DHCP to static conversion
├── config/
│   ├── sources.list.pve         # Apt sources template
│   └── interfaces.template      # Network config template
└── tests/                       # Test suite
```

## What Happens When You Boot

```
┌─────────────────────────────────────────────────────────────┐
│  USB Boot                                                    │
│  └─→ Proxmox Installer (graphical)                          │
│      └─→ Select disk, configure network (DHCP)              │
│          └─→ Installation completes, reboot                 │
│                                                              │
│  First Boot (AUTOMATIC)                                      │
│  └─→ Systemd service runs first-boot-setup.sh               │
│      └─→ Waits for network ✓                                │
│      └─→ Configures repos ✓                                  │
│      └─→ Installs Node.js ✓                                  │
│      └─→ Installs Claude Code ✓                              │
│      └─→ Starts Claude session ✓                             │
│                                                              │
│  You SSH in                                                  │
│  └─→ Type 'tm' to attach to Claude                          │
│      └─→ Authenticate if needed                              │
│      └─→ Start configuring your server!                      │
└─────────────────────────────────────────────────────────────┘
```

## Manual Installation

If you prefer to run steps manually:

```bash
# On the Proxmox server after installation

# 1. Add no-subscription repo
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
apt update

# 2. Install Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# 3. Install Claude Code
npm install -g @anthropic-ai/claude-code

# 4. Run Claude
claude
```

## Configuration Options

### ZFS Storage
The installer scripts support:
- Single disk
- Mirror (2+ disks)
- RAIDZ1 (3+ disks)
- RAIDZ2 (4+ disks)

### Network
- Initial setup uses DHCP
- Use Claude to configure static IP after installation

## Troubleshooting

### USB not booting
- Ensure Secure Boot is disabled in BIOS
- Try both UEFI and Legacy boot modes
- Verify USB was created successfully

### Network issues after PVE install
- Check cable connection
- Verify DHCP is available on your network
- Use `ip addr` to check interface status

### Claude authentication
- Run `claude auth login` in the tmux session
- Follow the prompts to authenticate with Anthropic

## License

MIT
