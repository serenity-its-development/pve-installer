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

# Step tracking
$script:TotalSteps = 5
$script:CurrentStep = 0
$script:StepStartTime = $null
$script:OverallStartTime = $null

# --- Progress & Output Helpers ---

function Write-StepHeader {
    param([string]$Description)

    $script:CurrentStep++
    $script:StepStartTime = Get-Date

    $bar = "=" * 50
    Write-Host ""
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host "  Step $($script:CurrentStep)/$($script:TotalSteps): $Description" -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-StepComplete {
    param([string]$Message)

    $elapsed = (Get-Date) - $script:StepStartTime
    $timeStr = "{0:mm\:ss}" -f $elapsed
    Write-Host "  [OK] $Message ($timeStr)" -ForegroundColor Green
}

function Write-Status { param([string]$Message) Write-Host "  [*] $Message" -ForegroundColor Gray }
function Write-Success { param([string]$Message) Write-Host "  [+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  [!] $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "  [-] $Message" -ForegroundColor Red }

function Write-ProgressBar {
    param(
        [int]$Percent,
        [string]$Status,
        [int]$BarWidth = 40
    )

    $filled = [math]::Floor($BarWidth * $Percent / 100)
    $empty = $BarWidth - $filled
    $bar = ("#" * $filled) + ("-" * $empty)

    Write-Host -NoNewline "`r  [$bar] $Percent% $Status    "
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- USB Detection ---

function Get-USBDrives {
    $result = @()

    # Method 1: Get-Disk with USB BusType
    $usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })

    # Method 2: Fall back to WMI to catch drives that report different BusType
    if (-not $usbDisks -or $usbDisks.Count -eq 0) {
        Write-Status "No USB BusType found, checking WMI..."
        $wmiUsb = Get-WmiObject Win32_DiskDrive | Where-Object {
            $_.InterfaceType -eq 'USB' -or
            $_.PNPDeviceID -like '*USB*' -or
            $_.MediaType -eq 'Removable Media'
        }

        if ($wmiUsb) {
            foreach ($wmiDisk in $wmiUsb) {
                $diskNum = $wmiDisk.DeviceID -replace '.*(\d+)$', '$1'
                $usbDisks += Get-Disk -Number $diskNum -ErrorAction SilentlyContinue
            }
        }
    }

    # Method 3: Check for removable drives via volume
    if (-not $usbDisks -or $usbDisks.Count -eq 0) {
        Write-Status "Checking for removable volumes..."
        $removable = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }

        if ($removable) {
            foreach ($vol in $removable) {
                if ($vol.DriveLetter) {
                    $part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction SilentlyContinue
                    if ($part) {
                        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
                        if ($disk -and $disk -notin $usbDisks) {
                            $usbDisks += $disk
                        }
                    }
                }
            }
        }
    }

    if (-not $usbDisks -or $usbDisks.Count -eq 0) {
        # Show what we DO see so the user can troubleshoot
        Write-Warn "No USB drives detected. Here's what Windows sees:"
        Write-Host ""
        Get-Disk | ForEach-Object {
            Write-Host "    Disk $($_.Number): $($_.FriendlyName) | Bus: $($_.BusType) | Size: $([math]::Round($_.Size/1GB,1)) GB" -ForegroundColor Gray
        }
        Write-Host ""
        $removableVols = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }
        if ($removableVols) {
            Write-Host "    Removable volumes:" -ForegroundColor Gray
            $removableVols | ForEach-Object {
                Write-Host "      $($_.DriveLetter): $($_.FileSystemLabel) ($($_.DriveType))" -ForegroundColor Gray
            }
        }
        Write-Host ""
        return $result
    }

    foreach ($disk in $usbDisks) {
        $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        $added = $false

        if ($partitions) {
            foreach ($part in $partitions) {
                if ($part.DriveLetter) {
                    $result += [PSCustomObject]@{
                        DriveLetter = $part.DriveLetter
                        DiskNumber  = $disk.Number
                        Size        = [math]::Round($disk.Size / 1GB, 1)
                        Model       = $disk.FriendlyName
                        BusType     = $disk.BusType
                    }
                    $added = $true
                }
            }
        }

        if (-not $added) {
            $result += [PSCustomObject]@{
                DriveLetter = $null
                DiskNumber  = $disk.Number
                Size        = [math]::Round($disk.Size / 1GB, 1)
                Model       = $disk.FriendlyName
                BusType     = $disk.BusType
            }
        }
    }

    return $result
}

function Select-USBDrive {
    Write-StepHeader "Select USB Drive"

    Write-Status "Scanning for USB drives..."

    $drives = @(Get-USBDrives)

    if ($drives.Count -eq 0) {
        Write-Err "No USB drives found. Please insert a USB drive."
        exit 1
    }

    Write-Success "Found $($drives.Count) USB drive(s)"
    Write-Host ""
    Write-Host "  Available USB Drives:" -ForegroundColor White
    Write-Host "  ---------------------" -ForegroundColor DarkGray

    for ($i = 0; $i -lt $drives.Count; $i++) {
        $drive = $drives[$i]
        $letter = if ($drive.DriveLetter) { "$($drive.DriveLetter):" } else { "(No letter)" }
        Write-Host "    $($i + 1). $letter - $($drive.Model) ($($drive.Size) GB)" -ForegroundColor White
    }

    Write-Host ""
    $selection = Read-Host "  Select drive (1-$($drives.Count))"
    $index = [int]$selection - 1

    if ($index -lt 0 -or $index -ge $drives.Count) {
        Write-Err "Invalid selection"
        exit 1
    }

    $selected = $drives[$index]
    Write-StepComplete "Selected: $($selected.Model) ($($selected.Size) GB)"
    return $selected
}

# --- Downloads ---

function Download-WithProgress {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$DisplayName
    )

    # Try BITS first (has built-in progress)
    try {
        Write-Status "Method: BITS Transfer"
        $bitsJob = Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName $DisplayName -Asynchronous

        while ($bitsJob.JobState -eq 'Transferring' -or $bitsJob.JobState -eq 'Connecting') {
            $transferred = $bitsJob.BytesTransferred
            $total = $bitsJob.BytesTotal

            if ($total -gt 0) {
                $percent = [math]::Round(($transferred / $total) * 100)
                $mbTransferred = [math]::Round($transferred / 1MB)
                $mbTotal = [math]::Round($total / 1MB)
                Write-ProgressBar -Percent $percent -Status "${mbTransferred} MB / ${mbTotal} MB"
            }
            else {
                $mbTransferred = [math]::Round($transferred / 1MB)
                Write-Host -NoNewline "`r  [Downloading...] ${mbTransferred} MB transferred    "
            }

            Start-Sleep -Milliseconds 500
        }

        if ($bitsJob.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $bitsJob
            Write-Host ""
            return $true
        }
        else {
            Write-Host ""
            Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
            throw "BITS transfer ended with state: $($bitsJob.JobState)"
        }
    }
    catch {
        Write-Host ""
        Write-Warn "BITS transfer failed: $_"
        Write-Status "Falling back to WebClient with progress..."

        # Fallback: WebClient with event-based progress
        try {
            $webClient = New-Object System.Net.WebClient

            $downloadComplete = $false

            Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -Action {
                $percent = $EventArgs.ProgressPercentage
                $mbReceived = [math]::Round($EventArgs.BytesReceived / 1MB)
                $mbTotal = [math]::Round($EventArgs.TotalBytesToReceive / 1MB)
                Write-Host -NoNewline "`r  [$('#' * [math]::Floor(40 * $percent / 100))$('-' * (40 - [math]::Floor(40 * $percent / 100)))] ${percent}% ${mbReceived} MB / ${mbTotal} MB    "
            } | Out-Null

            Register-ObjectEvent -InputObject $webClient -EventName DownloadFileCompleted -Action {
                $script:downloadComplete = $true
            } | Out-Null

            $webClient.DownloadFileAsync([Uri]$Url, $Destination)

            while (-not $downloadComplete) {
                Start-Sleep -Milliseconds 200
            }

            Write-Host ""
            $webClient.Dispose()
            return $true
        }
        catch {
            Write-Host ""
            Write-Warn "WebClient failed too, using Invoke-WebRequest (no granular progress)..."
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
            $ProgressPreference = 'Continue'
            return $true
        }
    }
}

function Download-ProxmoxISO {
    Write-StepHeader "Download Proxmox VE ISO"

    if (-not (Test-Path $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir | Out-Null
    }

    $isoPath = Join-Path $DownloadDir "proxmox-ve_$PveVersion.iso"

    if ((Test-Path $isoPath) -and $SkipDownload) {
        $sizeMB = [math]::Round((Get-Item $isoPath).Length / 1MB)
        Write-Success "Using cached ISO (${sizeMB} MB): $isoPath"
        Write-StepComplete "ISO ready (cached)"
        return $isoPath
    }

    if (Test-Path $isoPath) {
        $sizeMB = [math]::Round((Get-Item $isoPath).Length / 1MB)
        Write-Status "Found existing download (${sizeMB} MB)"
        Write-Status "Re-downloading to ensure latest version..."
    }

    Write-Status "Source: $PveIsoUrl"
    Write-Status "Size: ~1.2 GB"
    Write-Host ""

    Download-WithProgress -Url $PveIsoUrl -Destination $isoPath -DisplayName "Proxmox VE $PveVersion ISO"

    $sizeMB = [math]::Round((Get-Item $isoPath).Length / 1MB)
    Write-StepComplete "Downloaded ${sizeMB} MB"
    return $isoPath
}

function Download-Rufus {
    $rufusPath = Join-Path $DownloadDir "rufus.exe"

    if (Test-Path $rufusPath) {
        Write-Status "Using cached Rufus"
        return $rufusPath
    }

    Write-Status "Downloading Rufus..."
    Download-WithProgress -Url $RufusUrl -Destination $rufusPath -DisplayName "Rufus"
    Write-Success "Rufus downloaded"

    return $rufusPath
}

# --- Auto-Setup ---

function Create-AutoSetupScript {
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

# --- Setup Files ---

function Create-InstructionFiles {
    param([string]$AnswerToml)

    Write-StepHeader "Create Setup Files"

    Write-Status "Generating answer file..."
    $instructionsDir = Join-Path $DownloadDir "pve-installer-files"
    New-Item -ItemType Directory -Path $instructionsDir -Force | Out-Null

    $AnswerToml | Out-File -FilePath (Join-Path $instructionsDir "answer.toml") -Encoding UTF8 -NoNewline
    Write-Success "answer.toml created"

    Write-Status "Generating quick-start guide..."

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

Just log in at the console and type: tm

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
    Write-Success "QUICK-START.txt created"

    Write-StepComplete "Setup files ready"
    return $instructionsDir
}

# --- USB Writing ---

function Write-USBWithRufus {
    param(
        [string]$IsoPath,
        [PSCustomObject]$UsbDrive
    )

    Write-Status "Downloading Rufus..."
    $rufusPath = Download-Rufus

    Write-Host ""
    Write-Host "  ==========================================" -ForegroundColor Yellow
    Write-Host "    RUFUS WILL NOW OPEN" -ForegroundColor Yellow
    Write-Host "  ==========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  In Rufus:" -ForegroundColor White
    Write-Host "    1. Select your USB drive: $($UsbDrive.Model)" -ForegroundColor Gray
    Write-Host "    2. Click SELECT and choose:" -ForegroundColor Gray
    Write-Host "       $IsoPath" -ForegroundColor Cyan
    Write-Host "    3. Click START" -ForegroundColor Gray
    Write-Host "    4. Choose 'Write in DD Image mode' when prompted" -ForegroundColor Gray
    Write-Host "    5. Wait for completion" -ForegroundColor Gray
    Write-Host ""

    Read-Host "  Press Enter to open Rufus"

    Start-Process -FilePath $rufusPath -Wait
}

function Write-USBDirect {
    param(
        [string]$IsoPath,
        [PSCustomObject]$UsbDrive
    )

    $diskNumber = $UsbDrive.DiskNumber

    Write-Host ""
    Write-Host "  WARNING: This will ERASE ALL DATA on Disk $diskNumber ($($UsbDrive.Model))" -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "  Type 'YES' to continue"

    if ($confirm -ne "YES") {
        Write-Warn "Aborted"
        exit 0
    }

    Write-Status "Clearing disk..."
    Clear-Disk -Number $diskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    Write-Success "Disk cleared"

    Write-Status "Writing ISO to USB..."
    $source = [System.IO.File]::OpenRead($IsoPath)
    $dest = [System.IO.File]::OpenWrite("\\.\PhysicalDrive$diskNumber")

    $buffer = New-Object byte[] (4MB)
    $totalBytes = $source.Length
    $totalMB = [math]::Round($totalBytes / 1MB)
    $bytesWritten = 0
    $writeStart = Get-Date

    try {
        while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $dest.Write($buffer, 0, $read)
            $bytesWritten += $read
            $percent = [math]::Round(($bytesWritten / $totalBytes) * 100)
            $mbWritten = [math]::Round($bytesWritten / 1MB)

            # Calculate speed and ETA
            $elapsed = (Get-Date) - $writeStart
            if ($elapsed.TotalSeconds -gt 0) {
                $speedMBs = [math]::Round($mbWritten / $elapsed.TotalSeconds, 1)
                $remainingMB = $totalMB - $mbWritten
                if ($speedMBs -gt 0) {
                    $etaSeconds = [math]::Round($remainingMB / $speedMBs)
                    $etaStr = "ETA {0:mm\:ss}" -f [TimeSpan]::FromSeconds($etaSeconds)
                }
                else {
                    $etaStr = "ETA --:--"
                }
                Write-ProgressBar -Percent $percent -Status "${mbWritten}/${totalMB} MB @ ${speedMBs} MB/s - $etaStr"
            }
            else {
                Write-ProgressBar -Percent $percent -Status "${mbWritten}/${totalMB} MB"
            }
        }
    }
    finally {
        $source.Close()
        $dest.Close()
    }

    Write-Host ""
    $writeElapsed = (Get-Date) - $writeStart
    $avgSpeed = [math]::Round($totalMB / $writeElapsed.TotalSeconds, 1)
    Write-Success "ISO written ($totalMB MB in {0:mm\:ss} @ $avgSpeed MB/s)" -f $writeElapsed
}

function Write-IsoToUSB {
    Write-StepHeader "Write ISO to USB"

    Write-Host "  Choose write method:" -ForegroundColor White
    Write-Host "    1. Use Rufus (Recommended - more reliable)" -ForegroundColor Gray
    Write-Host "    2. Direct write (Faster, no extra software)" -ForegroundColor Gray
    Write-Host ""
    $method = Read-Host "  Select (1 or 2)"

    if ($method -eq "2") {
        Write-USBDirect -IsoPath $script:isoPath -UsbDrive $script:selectedDrive
    }
    else {
        Write-USBWithRufus -IsoPath $script:isoPath -UsbDrive $script:selectedDrive
    }

    Write-StepComplete "USB drive written"
}

# --- Completion ---

function Show-Completion {
    param([string]$InstructionsDir)

    $totalElapsed = (Get-Date) - $script:OverallStartTime
    $totalTime = "{0:mm\:ss}" -f $totalElapsed

    Write-Host ""
    Write-Host "  ==========================================" -ForegroundColor Green
    Write-Host "    USB DRIVE READY!  (Total time: $totalTime)" -ForegroundColor Green
    Write-Host "  ==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  WHAT'S ON THE USB:" -ForegroundColor Yellow
    Write-Host "    - Proxmox VE $PveVersion installer" -ForegroundColor White
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "    1. Plug USB into your server" -ForegroundColor White
    Write-Host "    2. Boot from USB (F12/F2/DEL for boot menu)" -ForegroundColor White
    Write-Host "    3. Install Proxmox VE" -ForegroundColor White
    Write-Host "    4. After reboot, log in and type: " -NoNewline -ForegroundColor White
    Write-Host "tm" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  FILES CREATED:" -ForegroundColor Yellow
    Write-Host "    $InstructionsDir\QUICK-START.txt" -ForegroundColor Gray
    Write-Host "    $InstructionsDir\answer.toml" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  If auto-setup doesn't run, log in and run:" -ForegroundColor Yellow
    Write-Host "    curl -fsSL $SetupScriptUrl | bash" -ForegroundColor Cyan
    Write-Host ""
}

# --- Main ---

function Main {
    $script:OverallStartTime = Get-Date

    Write-Host ""
    Write-Host "  ==========================================" -ForegroundColor Cyan
    Write-Host "    PVE Installer - USB Creator" -ForegroundColor Cyan
    Write-Host "    Proxmox VE $PveVersion + Claude Code" -ForegroundColor DarkCyan
    Write-Host "  ==========================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Administrator)) {
        Write-Err "Please run PowerShell as Administrator"
        exit 1
    }

    Write-Success "Running as Administrator"

    # Step 1: Select USB
    $script:selectedDrive = Select-USBDrive

    # Step 2: Download ISO
    $script:isoPath = Download-ProxmoxISO

    # Step 3: Create setup files
    $hookScript = Create-AutoSetupScript
    $answerToml = Create-AnswerFile -HookScript $hookScript
    $instructionsDir = Create-InstructionFiles -AnswerToml $answerToml

    # Step 4: Write to USB
    Write-IsoToUSB

    # Step 5: Done
    $script:CurrentStep++
    Show-Completion -InstructionsDir $instructionsDir
}

Main
