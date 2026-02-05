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

**Option A: Linux (Full Customization)**
- Debian/Ubuntu Linux
- `live-build` package
- `debootstrap`
- Root/sudo access

**Option B: Windows 11 (Quick Build)**
- Windows 11 or Windows 10
- PowerShell (Run as Administrator)
- Optional: WSL2 for full customization

### Target Server
- x86_64 system with UEFI or Legacy BIOS
- Minimum 4GB RAM (8GB+ recommended for ZFS)
- Network connectivity (DHCP initially)
- Storage drive(s) for ZFS

## Quick Start

### 1. Build the USB Image

**On Linux:**
```bash
cd build
sudo ./build-usb.sh
```

This creates `pve-installer.iso` which can be written to USB:

```bash
sudo dd if=pve-installer.iso of=/dev/sdX bs=4M status=progress
```

**On Windows 11 (PowerShell as Administrator):**
```powershell
cd build

# Direct USB write (downloads Debian Live + adds scripts)
.\build-usb.ps1

# Or use WSL for full customization
.\build-usb.ps1 -UseWSL
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

## Project Structure

```
pve-installer/
├── build/                  # USB image build scripts
│   ├── build-usb.sh        # Linux build script
│   ├── build-usb.ps1       # Windows build script
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
├── tests/                  # Test suite
│   ├── unit/               # Unit tests (Bats)
│   ├── mocks/              # Mock commands for testing
│   └── run_tests.sh        # Test runner
└── README.md
```

## Testing

Run the test suite:

```bash
# Run all tests
cd tests
./run_tests.sh

# Run only unit tests
./run_tests.sh unit

# Run with verbose output
./run_tests.sh -v
```

Tests are automatically run on push via GitHub Actions.

## License

MIT
