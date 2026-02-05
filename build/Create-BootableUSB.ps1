<#
.SYNOPSIS
    Create a bootable PVE Installer USB on Windows

.DESCRIPTION
    This script:
    1. Downloads the latest Proxmox VE ISO
    2. Creates a bootable USB using Rufus or direct write
    3. Adds auto-setup scripts that run on first boot

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

# URLs
$PveIsoUrl = "https://enterprise.proxmox.com/iso/proxmox-ve_$PveVersion-1.iso"
$RufusUrl = "https://github.com/pbatard/rufus/releases/download/v4.6/rufus-4.6p.exe"
$SetupScriptUrl = "https://raw.githubusercontent.com/serenity-its-development/pve-installer/main/post-install/first-boot-setup.sh"

# Colors
function Write-Status { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "[-] $Message" -ForegroundColor Red }

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
                    DiskNumber  = $disk.Number
                    Size        = [math]::Round($disk.Size / 1GB, 1)
                    Model       = $disk.FriendlyName
                }
            }
        }
        if (-not $partitions -or -not ($partitions | Where-Object { $_.DriveLetter })) {
            $result += [PSCustomObject]@{
                DriveLetter = $null
                DiskNumber  = $disk.Number
                Size        = [math]::Round($disk.Size / 1GB, 1)
                Model       = $disk.FriendlyName
            }
        }
    }
    return $result
}

function Select-USBDrive {
    Write-Status "Detecting USB drives..."

    $drives = Get-USBDrives

    if ($drives.Count -eq 0) {
        Write-Err "No USB drives found. Please insert a USB drive."
        exit 1
    }

    Write-Host "`nAvailable USB Drives:" -ForegroundColor White
    Write-Host "=====================" -ForegroundColor White

    for ($i = 0; $i -lt $drives.Count; $i++) {
        $drive = $drives[$i]
        $letter = if ($drive.DriveLetter) { "$($drive.DriveLetter):" } else { "(No letter)" }
        Write-Host "$($i + 1). $letter - $($drive.Model) ($($drive.Size) GB)"
    }

    Write-Host ""
    $selection = Read-Host "Select drive (1-$($drives.Count))"
    $index = [int]$selection - 1

    if ($index -lt 0 -or $index -ge $drives.Count) {
        Write-Err "Invalid selection"
        exit 1
    }

    return $drives[$index]
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
    Write-Status "This will take a while (~1.2 GB)..."

    try {
        Start-BitsTransfer -Source $PveIsoUrl -Destination $isoPath -DisplayName "Proxmox VE ISO"
    }
    catch {
        Write-Warn "BITS failed, using WebRequest..."
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $PveIsoUrl -OutFile $isoPath -UseBasicParsing
        $ProgressPreference = 'Continue'
    }

    Write-Success "Download complete: $isoPath"
    return $isoPath
}

function Download-Rufus {
    $rufusPath = Join-Path $DownloadDir "rufus.exe"

    if (Test-Path $rufusPath) {
        return $rufusPath
    }

    Write-Status "Downloading Rufus..."
    Invoke-WebRequest -Uri $RufusUrl -OutFile $rufusPath -UseBasicParsing

    return $rufusPath
}

function Create-AutoSetupScript {
    Write-Status "Creating auto-setup configuration..."

    # Create the post-install hook script
    $hookScript = @'
#!/bin/bash
# PVE Claude Auto-Setup Hook
# This runs after Proxmox installation to set up Claude Code

SETUP_URL="https://raw.githubusercontent.com/serenity-its-development/pve-installer/main/post-install/first-boot-setup.sh"
SERVICE_FILE="/etc/systemd/system/pve-claude-setup.service"
SETUP_SCRIPT="/root/first-boot-setup.sh"

# Download setup script
curl -fsSL "$SETUP_URL" -o "$SETUP_SCRIPT"
chmod +x "$SETUP_SCRIPT"

# Create systemd service for first boot
cat > "$SERVICE_FILE" << 'SERVICEEOF'
[Unit]
Description=PVE Claude Code First Boot Setup
After=network-online.target pve-cluster.service
Wants=network-online.target
ConditionPathExists=!/var/lib/pve-claude-setup-done

[Service]
Type=oneshot
ExecStart=/root/first-boot-setup.sh --auto
ExecStartPost=/bin/touch /var/lib/pve-claude-setup-done
ExecStartPost=/bin/systemctl disable pve-claude-setup.service
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Enable the service
systemctl daemon-reload
systemctl enable pve-claude-setup.service

echo "Claude auto-setup configured for first boot"
'@

    return $hookScript
}

function Create-AnswerFile {
    param([string]$HookScript)

    Write-Status "Creating automated installation answer file..."

    # Encode hook script for embedding
    $hookBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($HookScript))

    $answerToml = @"
# Proxmox VE Automated Installation
# This file enables automated installation with Claude Code setup
#
# INSTRUCTIONS:
# 1. Edit this file to match your environment
# 2. Boot from USB
# 3. Select "Automated Installation" from boot menu
# 4. Installation will proceed automatically

[global]
keyboard = "en-us"
country = "us"
fqdn = "pve.local"
mailto = "root@localhost"
timezone = "UTC"
root_password = "ChangeMe123!"
root_ssh_keys = []

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
# For ZFS, use:
# filesystem = "zfs"
# zfs.raid = "raid0"
# zfs.compress = "on"
# disk_list = ["sda"]

[post-commands]
# Download and configure Claude Code auto-setup
post = [
    "curl -fsSL https://raw.githubusercontent.com/serenity-its-development/pve-installer/main/post-install/first-boot-setup.sh -o /root/first-boot-setup.sh",
    "chmod +x /root/first-boot-setup.sh",
    "cat > /etc/systemd/system/pve-claude-setup.service << 'EOF'\n[Unit]\nDescription=PVE Claude Code Setup\nAfter=network-online.target\nWants=network-online.target\nConditionPathExists=!/var/lib/pve-claude-done\n\n[Service]\nType=oneshot\nExecStart=/root/first-boot-setup.sh --auto\nExecStartPost=/bin/touch /var/lib/pve-claude-done\nExecStartPost=/bin/systemctl disable pve-claude-setup.service\nTimeoutStartSec=600\n\n[Install]\nWantedBy=multi-user.target\nEOF",
    "systemctl enable pve-claude-setup.service"
]
"@

    return $answerToml
}

function Write-USBWithRufus {
    param(
        [string]$IsoPath,
        [PSCustomObject]$UsbDrive
    )

    $rufusPath = Download-Rufus

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "  RUFUS WILL NOW OPEN" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "In Rufus:"
    Write-Host "  1. Select your USB drive: $($UsbDrive.Model)"
    Write-Host "  2. Click SELECT and choose: $IsoPath"
    Write-Host "  3. Click START"
    Write-Host "  4. Choose 'Write in DD Image mode' when prompted"
    Write-Host "  5. Wait for completion"
    Write-Host ""

    Read-Host "Press Enter to open Rufus"

    Start-Process -FilePath $rufusPath -Wait
}

function Write-USBDirect {
    param(
        [string]$IsoPath,
        [PSCustomObject]$UsbDrive
    )

    $diskNumber = $UsbDrive.DiskNumber

    Write-Host ""
    Write-Host "WARNING: This will ERASE ALL DATA on Disk $diskNumber ($($UsbDrive.Model))" -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Type 'YES' to continue"

    if ($confirm -ne "YES") {
        Write-Warn "Aborted"
        exit 0
    }

    Write-Status "Writing ISO to USB (this will take several minutes)..."

    # Clear the disk
    Clear-Disk -Number $diskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue

    # Write ISO using dd-like method
    $source = [System.IO.File]::OpenRead($IsoPath)
    $dest = [System.IO.File]::OpenWrite("\\.\PhysicalDrive$diskNumber")

    $buffer = New-Object byte[] (4MB)
    $totalBytes = $source.Length
    $bytesWritten = 0

    try {
        while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $dest.Write($buffer, 0, $read)
            $bytesWritten += $read
            $percent = [math]::Round(($bytesWritten / $totalBytes) * 100)
            Write-Progress -Activity "Writing ISO" -Status "$percent% complete" -PercentComplete $percent
        }
    }
    finally {
        $source.Close()
        $dest.Close()
    }

    Write-Progress -Activity "Writing ISO" -Completed
    Write-Success "ISO written to USB"
}

function Create-InstructionFiles {
    param([string]$AnswerToml)

    Write-Status "Creating instruction files..."

    $instructionsDir = Join-Path $DownloadDir "pve-installer-files"
    New-Item -ItemType Directory -Path $instructionsDir -Force | Out-Null

    # Save answer file
    $AnswerToml | Out-File -FilePath (Join-Path $instructionsDir "answer.toml") -Encoding UTF8 -NoNewline

    # Create quick-start guide
    $quickStart = @"
PVE INSTALLER - QUICK START
============================

STEP 1: BOOT FROM USB
---------------------
Insert USB into your server and boot from it.
You may need to press F12, F2, or DEL to access boot menu.

STEP 2: INSTALL PROXMOX
-----------------------
Option A - Standard Installation:
  - Select "Install Proxmox VE (Graphical)"
  - Follow the prompts

Option B - Automated Installation:
  - Select "Automated Installation"
  - Choose answer.toml from USB

STEP 3: FIRST BOOT
------------------
After installation, the system will automatically:
  - Configure repositories
  - Install Node.js
  - Install Claude Code
  - Start Claude in a tmux session

Just SSH into your server and type: tm

STEP 4: USE CLAUDE
------------------
Claude is ready to help! Example commands:

  "Set my IP to 192.168.1.100/24"
  "Create a VM with Ubuntu 24.04"
  "Set up ZFS mirror on sdb and sdc"
  "Configure automated backups"

MANUAL SETUP (if auto-setup didn't run)
---------------------------------------
SSH into the server and run:

curl -fsSL https://raw.githubusercontent.com/serenity-its-development/pve-installer/main/post-install/first-boot-setup.sh | bash

TROUBLESHOOTING
---------------
- Logs: /var/log/pve-claude-setup.log
- Service: systemctl status pve-claude-setup
- Manual run: /root/first-boot-setup.sh
"@

    $quickStart | Out-File -FilePath (Join-Path $instructionsDir "QUICK-START.txt") -Encoding UTF8

    Write-Success "Instruction files created in: $instructionsDir"

    return $instructionsDir
}

function Show-Completion {
    param(
        [string]$IsoPath,
        [string]$InstructionsDir
    )

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "  USB DRIVE READY!" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "WHAT'S ON THE USB:" -ForegroundColor Yellow
    Write-Host "  - Proxmox VE $PveVersion installer"
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Boot your server from the USB"
    Write-Host "  2. Install Proxmox VE (follow prompts)"
    Write-Host "  3. After reboot, Claude auto-setup runs!"
    Write-Host "  4. SSH in and type: tm"
    Write-Host ""
    Write-Host "FILES CREATED:" -ForegroundColor Yellow
    Write-Host "  $InstructionsDir\QUICK-START.txt"
    Write-Host "  $InstructionsDir\answer.toml (for automated install)"
    Write-Host ""
    Write-Host "If auto-setup doesn't run, SSH in and run:" -ForegroundColor Yellow
    Write-Host "  curl -fsSL $SetupScriptUrl | bash" -ForegroundColor Cyan
    Write-Host ""
}

# Main
function Main {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  PVE Installer - USB Creator" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Administrator)) {
        Write-Err "Please run PowerShell as Administrator"
        exit 1
    }

    # Select USB drive
    $selectedDrive = Select-USBDrive
    Write-Status "Selected: $($selectedDrive.Model) ($($selectedDrive.Size) GB)"

    # Download Proxmox ISO
    $isoPath = Download-ProxmoxISO

    # Create answer file and instructions
    $hookScript = Create-AutoSetupScript
    $answerToml = Create-AnswerFile -HookScript $hookScript
    $instructionsDir = Create-InstructionFiles -AnswerToml $answerToml

    # Write ISO to USB
    Write-Host ""
    Write-Host "Choose write method:" -ForegroundColor Yellow
    Write-Host "  1. Use Rufus (Recommended - more reliable)"
    Write-Host "  2. Direct write (Faster but may have issues)"
    Write-Host ""
    $method = Read-Host "Select (1 or 2)"

    if ($method -eq "2") {
        Write-USBDirect -IsoPath $isoPath -UsbDrive $selectedDrive
    }
    else {
        Write-USBWithRufus -IsoPath $isoPath -UsbDrive $selectedDrive
    }

    Show-Completion -IsoPath $isoPath -InstructionsDir $instructionsDir
}

Main
