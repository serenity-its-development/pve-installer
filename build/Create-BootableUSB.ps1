<#
.SYNOPSIS
    Create a bootable PVE Installer USB on Windows

.DESCRIPTION
    This script:
    1. Downloads the latest Proxmox VE ISO
    2. Formats and prepares a USB drive
    3. Makes it bootable with automated installation support
    4. Adds Claude Code setup scripts

.PARAMETER DriveLetter
    The USB drive letter (e.g., "E"). Will prompt if not specified.

.PARAMETER PveVersion
    Proxmox VE version to download (default: latest 8.x)

.EXAMPLE
    .\Create-BootableUSB.ps1
    .\Create-BootableUSB.ps1 -DriveLetter E

.NOTES
    Run as Administrator
#>

param(
    [string]$DriveLetter,
    [string]$PveVersion = "8.3",
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DownloadDir = Join-Path $ScriptDir "downloads"
$VentoyDir = Join-Path $DownloadDir "ventoy"

# URLs
$PveIsoUrl = "https://enterprise.proxmox.com/iso/proxmox-ve_$PveVersion-1.iso"
$VentoyUrl = "https://github.com/ventoy/Ventoy/releases/download/v1.0.99/ventoy-1.0.99-windows.zip"

# Colors
function Write-Status { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warning { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Error { param([string]$Message) Write-Host "[-] $Message" -ForegroundColor Red }

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-USBDrives {
    $disks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
    $result = @()

    foreach ($disk in $disks) {
        $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        foreach ($part in $partitions) {
            if ($part.DriveLetter) {
                $result += [PSCustomObject]@{
                    DriveLetter = $part.DriveLetter
                    DiskNumber = $disk.Number
                    Size = [math]::Round($disk.Size / 1GB, 1)
                    Model = $disk.FriendlyName
                }
            }
        }
        # Include disks without drive letters
        if (-not $partitions -or -not ($partitions | Where-Object { $_.DriveLetter })) {
            $result += [PSCustomObject]@{
                DriveLetter = $null
                DiskNumber = $disk.Number
                Size = [math]::Round($disk.Size / 1GB, 1)
                Model = $disk.FriendlyName
            }
        }
    }
    return $result
}

function Select-USBDrive {
    Write-Status "Detecting USB drives..."

    $drives = Get-USBDrives

    if ($drives.Count -eq 0) {
        Write-Error "No USB drives found. Please insert a USB drive."
        exit 1
    }

    Write-Host "`nAvailable USB Drives:" -ForegroundColor White
    Write-Host "=====================" -ForegroundColor White

    for ($i = 0; $i -lt $drives.Count; $i++) {
        $drive = $drives[$i]
        $letter = if ($drive.DriveLetter) { "$($drive.DriveLetter):" } else { "(No letter)" }
        Write-Host "$($i + 1). $letter - $($drive.Model) ($($drive.Size) GB) [Disk $($drive.DiskNumber)]"
    }

    Write-Host ""
    $selection = Read-Host "Select drive (1-$($drives.Count))"
    $index = [int]$selection - 1

    if ($index -lt 0 -or $index -ge $drives.Count) {
        Write-Error "Invalid selection"
        exit 1
    }

    return $drives[$index]
}

function Install-Ventoy {
    param([int]$DiskNumber)

    Write-Status "Setting up Ventoy..."

    # Download Ventoy if needed
    $ventoyZip = Join-Path $DownloadDir "ventoy.zip"
    $ventoyExe = Join-Path $VentoyDir "Ventoy2Disk.exe"

    if (-not (Test-Path $ventoyExe)) {
        Write-Status "Downloading Ventoy..."

        if (-not (Test-Path $DownloadDir)) {
            New-Item -ItemType Directory -Path $DownloadDir | Out-Null
        }

        Invoke-WebRequest -Uri $VentoyUrl -OutFile $ventoyZip -UseBasicParsing

        Write-Status "Extracting Ventoy..."
        Expand-Archive -Path $ventoyZip -DestinationPath $DownloadDir -Force

        # Find the extracted folder
        $extractedFolder = Get-ChildItem -Path $DownloadDir -Directory | Where-Object { $_.Name -like "ventoy-*" } | Select-Object -First 1
        if ($extractedFolder) {
            Rename-Item -Path $extractedFolder.FullName -NewName "ventoy" -ErrorAction SilentlyContinue
        }
    }

    # Run Ventoy installation
    Write-Status "Installing Ventoy to disk $DiskNumber..."
    Write-Warning "This will ERASE ALL DATA on the drive!"

    $confirm = Read-Host "Type 'YES' to continue"
    if ($confirm -ne "YES") {
        Write-Warning "Aborted"
        exit 0
    }

    # Use Ventoy CLI
    $ventoyCli = Join-Path $VentoyDir "Ventoy2Disk.exe"

    # Ventoy needs to be run interactively, so we'll use a different approach
    # Format the drive manually and make it bootable

    Write-Status "Formatting and preparing USB drive..."

    # Clear the disk
    $disk = Get-Disk -Number $DiskNumber

    # Clear the disk
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue

    # Initialize as MBR (for BIOS compatibility) or GPT for UEFI
    Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction SilentlyContinue

    # Create a single partition
    $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -IsActive -AssignDriveLetter

    # Format as FAT32 (or NTFS for large drives)
    $size = (Get-Disk -Number $DiskNumber).Size
    if ($size -gt 32GB) {
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "PVEINSTALL" -Confirm:$false
    } else {
        Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel "PVEINSTALL" -Confirm:$false
    }

    Start-Sleep -Seconds 2

    # Get the new drive letter
    $newDriveLetter = (Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.DriveLetter }).DriveLetter

    Write-Success "Drive formatted: ${newDriveLetter}:"

    return $newDriveLetter
}

function Download-ProxmoxISO {
    Write-Status "Downloading Proxmox VE $PveVersion ISO..."

    if (-not (Test-Path $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir | Out-Null
    }

    $isoPath = Join-Path $DownloadDir "proxmox-ve_$PveVersion.iso"

    if ((Test-Path $isoPath) -and $SkipDownload) {
        Write-Success "Using existing ISO: $isoPath"
        return $isoPath
    }

    Write-Status "Downloading from: $PveIsoUrl"
    Write-Status "This may take a while (approximately 1.2 GB)..."

    try {
        # Try BITS transfer first (shows progress)
        Start-BitsTransfer -Source $PveIsoUrl -Destination $isoPath -DisplayName "Downloading Proxmox VE ISO"
    } catch {
        Write-Warning "BITS failed, using WebRequest..."

        # Fallback with progress
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($PveIsoUrl, $isoPath)
    }

    Write-Success "Download complete: $isoPath"
    return $isoPath
}

function Copy-FilesToUSB {
    param(
        [string]$DriveLetter,
        [string]$IsoPath
    )

    Write-Status "Copying files to USB drive..."

    $usbRoot = "${DriveLetter}:"

    # Copy ISO
    Write-Status "Copying Proxmox ISO (this may take several minutes)..."
    Copy-Item -Path $IsoPath -Destination "$usbRoot\proxmox-ve.iso" -Force

    # Create directory structure
    $dirs = @(
        "$usbRoot\pve-installer",
        "$usbRoot\pve-installer\scripts",
        "$usbRoot\pve-installer\config"
    )

    foreach ($dir in $dirs) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Copy installer scripts
    Write-Status "Copying installer scripts..."
    Copy-Item -Path "$ProjectRoot\installer\*" -Destination "$usbRoot\pve-installer\scripts\" -Recurse -Force
    Copy-Item -Path "$ProjectRoot\post-install\*" -Destination "$usbRoot\pve-installer\scripts\" -Recurse -Force
    Copy-Item -Path "$ProjectRoot\config\*" -Destination "$usbRoot\pve-installer\config\" -Recurse -Force

    Write-Success "Files copied to USB"
}

function Create-BootScript {
    param([string]$DriveLetter)

    Write-Status "Creating boot automation scripts..."

    $usbRoot = "${DriveLetter}:"

    # Create the main auto-install script
    $autoInstallScript = @'
#!/bin/bash
#
# PVE Auto-Installer
# This script runs after booting from USB to automate Proxmox installation
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[PVE-INSTALL]${NC} $1"; }
warn() { echo -e "${YELLOW}[PVE-INSTALL]${NC} $1"; }
error() { echo -e "${RED}[PVE-INSTALL]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Find USB mount point
find_usb_mount() {
    for mount in /run/live/medium /media/usb /mnt/usb; do
        if [[ -f "$mount/proxmox-ve.iso" ]]; then
            echo "$mount"
            return 0
        fi
    done

    # Try to find and mount
    for dev in /dev/sd*1; do
        if [[ -b "$dev" ]]; then
            mkdir -p /mnt/usb
            mount "$dev" /mnt/usb 2>/dev/null || continue
            if [[ -f "/mnt/usb/proxmox-ve.iso" ]]; then
                echo "/mnt/usb"
                return 0
            fi
            umount /mnt/usb 2>/dev/null || true
        fi
    done

    return 1
}

# Setup network
setup_network() {
    step "Setting up network..."

    # Try DHCP on all interfaces
    for iface in $(ls /sys/class/net | grep -v lo); do
        log "Trying DHCP on $iface..."
        ip link set "$iface" up
        dhclient "$iface" 2>/dev/null &
    done

    sleep 5

    # Check connectivity
    if ping -c 1 8.8.8.8 &>/dev/null; then
        log "Network connected!"
        ip addr show | grep "inet " | grep -v "127.0.0.1"
        return 0
    else
        warn "No network connectivity yet"
        return 1
    fi
}

# Test network
test_network() {
    step "Testing network connectivity..."

    local tests_passed=0

    # Test DNS
    if ping -c 1 google.com &>/dev/null; then
        log "DNS resolution: OK"
        ((tests_passed++))
    else
        warn "DNS resolution: FAILED"
    fi

    # Test HTTPS
    if curl -s --connect-timeout 5 https://www.proxmox.com &>/dev/null; then
        log "HTTPS connectivity: OK"
        ((tests_passed++))
    else
        warn "HTTPS connectivity: FAILED"
    fi

    if [[ $tests_passed -ge 1 ]]; then
        log "Network tests passed"
        return 0
    else
        error "Network tests failed"
        return 1
    fi
}

# Install Claude Code
install_claude() {
    step "Installing Claude Code..."

    # Check if Node.js is available
    if ! command -v node &>/dev/null; then
        log "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    # Install Claude Code
    log "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code

    log "Claude Code installed!"
}

# Start Claude in tmux
start_claude_session() {
    step "Starting Claude Code session..."

    # Install tmux if needed
    if ! command -v tmux &>/dev/null; then
        apt-get update && apt-get install -y tmux
    fi

    # Create a tmux session with Claude
    tmux new-session -d -s claude "claude"

    log "Claude Code running in tmux session 'claude'"
    log "Attach with: tmux attach -t claude"
}

# Main installation flow
main() {
    echo ""
    echo -e "${BLUE}=========================================="
    echo -e "  PVE Installer - Automated Setup"
    echo -e "==========================================${NC}"
    echo ""

    # Find USB
    USB_MOUNT=$(find_usb_mount) || {
        error "Could not find USB with Proxmox ISO"
        exit 1
    }
    log "Found USB at: $USB_MOUNT"

    # Setup network
    setup_network || {
        warn "Network setup incomplete, continuing anyway..."
    }

    # Test network
    test_network || {
        warn "Some network tests failed, continuing anyway..."
    }

    # Copy scripts
    log "Copying installer scripts..."
    cp -r "$USB_MOUNT/pve-installer/scripts/"* /root/ 2>/dev/null || true
    chmod +x /root/*.sh 2>/dev/null || true

    # Install Claude
    install_claude || {
        warn "Claude installation failed, you can install it later"
    }

    # Start Claude session
    start_claude_session

    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "  Setup Complete!"
    echo -e "==========================================${NC}"
    echo ""
    echo "Proxmox ISO location: $USB_MOUNT/proxmox-ve.iso"
    echo ""
    echo "Options:"
    echo "  1. Attach to Claude: tmux attach -t claude"
    echo "  2. Manual install:   /root/install-proxmox.sh"
    echo ""
    echo "In Claude, you can say:"
    echo "  'Install Proxmox on /dev/sda with ZFS'"
    echo ""
}

main "$@"
'@

    # Write the auto-install script
    $autoInstallScript | Out-File -FilePath "$usbRoot\pve-installer\auto-install.sh" -Encoding UTF8 -NoNewline

    # Create answer file template for automated PVE installation
    $answerToml = @'
# Proxmox VE Automated Installation Answer File
# Customize these values for your setup

[global]
keyboard = "en-us"
country = "us"
fqdn = "pve.local"
mailto = "admin@example.com"
timezone = "America/New_York"
root_password = "CHANGE_ME"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "zfs"
zfs.raid = "raid0"
zfs.compress = "on"
zfs.checksum = "on"
zfs.copies = 1
'@

    $answerToml | Out-File -FilePath "$usbRoot\pve-installer\config\answer.toml" -Encoding UTF8 -NoNewline

    # Create README on USB
    $readme = @"
PVE INSTALLER USB
=================

This USB contains:
- Proxmox VE ISO (proxmox-ve.iso)
- Automated installation scripts
- Claude Code setup

BOOT OPTIONS:

Option 1: Use Proxmox ISO directly
  - Boot from USB, select "Install Proxmox VE (Graphical)"
  - After installation, run the post-install scripts

Option 2: Boot to live Linux first (recommended)
  - Boot a Debian/Ubuntu live USB alongside this
  - Mount this USB and run: ./pve-installer/auto-install.sh
  - Claude will guide you through the installation

POST-INSTALLATION:
  1. SSH into your new Proxmox server
  2. Run: /root/setup-claude.sh
  3. Use Claude for further configuration

FILES:
  proxmox-ve.iso           - Proxmox VE installer
  pve-installer/
    auto-install.sh        - Automated setup script
    scripts/               - Installation scripts
    config/                - Configuration templates
"@

    $readme | Out-File -FilePath "$usbRoot\README.txt" -Encoding UTF8

    Write-Success "Boot scripts created"
}

function Show-Completion {
    param([string]$DriveLetter)

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "  USB Drive Ready!" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Drive: ${DriveLetter}:" -ForegroundColor White
    Write-Host ""
    Write-Host "Contents:" -ForegroundColor Yellow
    Write-Host "  - proxmox-ve.iso (Proxmox VE installer)"
    Write-Host "  - pve-installer/ (automation scripts)"
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Boot your server from this USB"
    Write-Host "2. Select 'Install Proxmox VE' from the menu"
    Write-Host "3. After PVE installation completes:"
    Write-Host "   - SSH to your new server"
    Write-Host "   - Run: bash /root/setup-claude.sh"
    Write-Host "   - Claude will help with remaining setup"
    Write-Host ""
    Write-Host "For fully automated installation:" -ForegroundColor Yellow
    Write-Host "   - Edit pve-installer/config/answer.toml"
    Write-Host "   - Use PVE's automated installer feature"
    Write-Host ""
}

# Main
function Main {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  PVE Installer - USB Creator" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    # Check admin
    if (-not (Test-Administrator)) {
        Write-Error "Please run PowerShell as Administrator"
        exit 1
    }

    # Select USB drive
    if ($DriveLetter) {
        $selectedDrive = Get-USBDrives | Where-Object { $_.DriveLetter -eq $DriveLetter }
        if (-not $selectedDrive) {
            Write-Error "USB drive $DriveLetter not found"
            exit 1
        }
    } else {
        $selectedDrive = Select-USBDrive
    }

    Write-Status "Selected: $($selectedDrive.Model) ($($selectedDrive.Size) GB)"

    # Download Proxmox ISO
    $isoPath = Download-ProxmoxISO

    # Format and prepare USB
    $newDriveLetter = Install-Ventoy -DiskNumber $selectedDrive.DiskNumber

    # Copy files
    Copy-FilesToUSB -DriveLetter $newDriveLetter -IsoPath $isoPath

    # Create boot scripts
    Create-BootScript -DriveLetter $newDriveLetter

    # Done
    Show-Completion -DriveLetter $newDriveLetter
}

Main
