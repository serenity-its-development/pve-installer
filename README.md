# PVE Installer

Automated Proxmox VE installation via bootable USB with Claude Code CLI integration.

## Overview

This project creates a bootable USB that:
1. Boots into a minimal Debian Live environment
2. Provides Claude Code CLI for interactive installation
3. Installs Proxmox VE with ZFS storage
4. Optionally installs Claude Code on the final system for ongoing management

## Requirements

### Build System
- Debian/Ubuntu Linux (for building the USB image)
- `live-build` package
- `debootstrap`
- Root/sudo access

### Target Server
- x86_64 system with UEFI or Legacy BIOS
- Minimum 4GB RAM (8GB+ recommended for ZFS)
- Network connectivity (DHCP initially)
- Storage drive(s) for ZFS

## Quick Start

### 1. Build the USB Image

```bash
cd build
sudo ./build-usb.sh
```

This creates `pve-installer.iso` which can be written to USB:

```bash
sudo dd if=pve-installer.iso of=/dev/sdX bs=4M status=progress
```

### 2. Boot and Install

1. Boot the target server from USB
2. System auto-configures network via DHCP
3. Run Claude Code: `claude`
4. Tell Claude to install Proxmox

### 3. Post-Installation

After Proxmox is installed and running:
- Access web UI at `https://<server-ip>:8006`
- SSH into the server
- Run `/root/setup-claude.sh` to install Claude Code for ongoing management

## Project Structure

```
pve-installer/
├── build/                  # USB image build scripts
│   ├── build-usb.sh        # Main build script
│   └── hooks/              # Live-build customization hooks
├── installer/              # Installation scripts (copied to USB)
│   ├── install-proxmox.sh  # Main Proxmox installation
│   ├── configure-zfs.sh    # ZFS pool setup
│   └── configure-network.sh # Network configuration
├── post-install/           # Scripts for after PVE is running
│   ├── setup-claude.sh     # Install Claude Code on PVE
│   └── configure-static-ip.sh # Convert to static IP
├── config/                 # Configuration templates
│   ├── sources.list.pve    # Proxmox apt sources
│   └── interfaces.template # Network interface template
└── README.md
```

## Configuration

### ZFS Options

The installer supports various ZFS configurations:
- Single disk
- Mirror (2+ disks)
- RAIDZ1 (3+ disks)
- RAIDZ2 (4+ disks)

### Network

- Initial: DHCP for installation
- Post-install: Can configure static IP via Claude Code

## Usage with Claude Code

Once booted into the live environment:

```
$ claude
> Install Proxmox on this server using ZFS mirror on /dev/sda and /dev/sdb
```

After installation, on the running Proxmox system:

```
$ claude
> Configure static IP 192.168.1.100/24 with gateway 192.168.1.1
> Create a new VM with 4 cores and 8GB RAM
> Set up a backup schedule for all VMs
```

## License

MIT
