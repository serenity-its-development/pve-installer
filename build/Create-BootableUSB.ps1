<#
.SYNOPSIS
    Create a bootable PVE Installer USB on Windows (fully automated)

.DESCRIPTION
    This script:
    1. Detects and selects a USB drive
    2. Downloads the latest Proxmox VE ISO
    3. Writes the ISO directly to the USB drive (DD mode)
    4. Creates an answer partition for automated PVE installation
    5. Configures first-boot Claude Code setup with optional disk cleanup

.PARAMETER DriveLetter
    The USB drive letter (e.g., "E"). Will prompt if not specified.

.PARAMETER PveVersion
    Proxmox VE version to download (default: latest 8.x)

.PARAMETER SkipDownload
    Use a previously downloaded ISO if available

.PARAMETER Hostname
    Hostname for the PVE installation (default: pve)

.PARAMETER Domain
    Domain for the PVE installation (default: local)

.PARAMETER Password
    Root password for PVE (will prompt if not specified)

.PARAMETER Filesystem
    Filesystem type: ext4 or zfs (default: ext4)

.PARAMETER CleanPreviousPve
    Add disk cleanup commands for previously installed PVE

.EXAMPLE
    .\Create-BootableUSB.ps1
    .\Create-BootableUSB.ps1 -Hostname myserver -Filesystem zfs -CleanPreviousPve
    .\Create-BootableUSB.ps1 -SkipDownload -Password "MyPass123!"

.NOTES
    Run as Administrator
#>

param(
    [string]$DriveLetter,
    [string]$PveVersion = "8.4",
    [switch]$SkipDownload,
    [string]$Hostname,
    [string]$Domain,
    [string]$Password,
    [string]$Filesystem,
    [switch]$CleanPreviousPve
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DownloadDir = Join-Path $ScriptDir "downloads"

# URLs
$PveIsoUrl = "https://enterprise.proxmox.com/iso/proxmox-ve_$PveVersion-1.iso"
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
    if ($usbDisks.Count -eq 0) {
        Write-Status "No USB BusType found, checking WMI..."
        $wmiUsb = Get-WmiObject Win32_DiskDrive | Where-Object {
            $_.InterfaceType -eq 'USB' -or
            $_.PNPDeviceID -like '*USB*' -or
            $_.MediaType -eq 'Removable Media'
        }

        if ($wmiUsb) {
            foreach ($wmiDisk in $wmiUsb) {
                $diskNum = $wmiDisk.DeviceID -replace '.*(\d+)$', '$1'
                $disk = Get-Disk -Number $diskNum -ErrorAction SilentlyContinue
                if ($disk) { $usbDisks += $disk }
            }
        }
    }

    # Method 3: Check for removable drives via volume
    if ($usbDisks.Count -eq 0) {
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

    if ($usbDisks.Count -eq 0) {
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
        $letter = $null

        if ($partitions) {
            foreach ($part in $partitions) {
                if ($part.DriveLetter) {
                    $letter = $part.DriveLetter
                    break
                }
            }
        }

        $result += [PSCustomObject]@{
            DriveLetter = $letter
            DiskNumber  = $disk.Number
            Size        = [math]::Round($disk.Size / 1GB, 1)
            Model       = $disk.FriendlyName
            BusType     = $disk.BusType
        }
    }

    return $result
}

function Select-USBDrive {
    Write-StepHeader "Select USB Drive"

    Write-Status "Scanning for USB drives..."

    $drives = @(Get-USBDrives)

    if ($drives.Count -eq 0) {
        Write-Err "No USB drives found. Please insert a USB drive and try again."
        exit 1
    }

    Write-Success "Found $($drives.Count) USB drive(s)"
    Write-Host ""
    Write-Host "  Available USB Drives:" -ForegroundColor White
    Write-Host "  ---------------------" -ForegroundColor DarkGray

    for ($i = 0; $i -lt $drives.Count; $i++) {
        $drive = $drives[$i]
        $letter = if ($drive.DriveLetter) { "$($drive.DriveLetter):" } else { "(No letter)" }
        Write-Host "    $($i + 1). $letter - $($drive.Model) ($($drive.Size) GB) [Disk $($drive.DiskNumber)]" -ForegroundColor White
    }

    Write-Host ""

    if ($drives.Count -eq 1) {
        $index = 0
        Write-Status "Auto-selected the only USB drive"
    }
    else {
        $selection = Read-Host "  Select drive (1-$($drives.Count))"
        $index = [int]$selection - 1

        if ($index -lt 0 -or $index -ge $drives.Count) {
            Write-Err "Invalid selection"
            exit 1
        }
    }

    $selected = $drives[$index]

    # Safety confirmation
    Write-Host ""
    Write-Host "  WARNING: ALL DATA on this drive will be ERASED:" -ForegroundColor Red
    Write-Host "    Disk $($selected.DiskNumber): $($selected.Model) ($($selected.Size) GB)" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Type 'YES' to continue"

    if ($confirm -ne "YES") {
        Write-Warn "Aborted by user"
        exit 0
    }

    Write-StepComplete "Selected: Disk $($selected.DiskNumber) - $($selected.Model) ($($selected.Size) GB)"
    return $selected
}

# --- Downloads ---

function Download-WithProgress {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$DisplayName
    )

    # Try BITS first (best progress reporting)
    try {
        Write-Status "Method: BITS Transfer"
        $bitsJob = Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName $DisplayName -Asynchronous

        while ($bitsJob.JobState -eq 'Transferring' -or $bitsJob.JobState -eq 'Connecting') {
            $transferred = $bitsJob.BytesTransferred
            $total = $bitsJob.BytesTotal

            # BytesTotal returns UInt64.MaxValue (-1 as unsigned) when unknown
            if ($total -gt 0 -and $total -lt 100GB) {
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

        # Fallback: Invoke-WebRequest
        try {
            Write-Status "Falling back to Invoke-WebRequest..."
            $ProgressPreference = 'Continue'
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
            return $true
        }
        catch {
            Write-Host ""
            Write-Err "All download methods failed: $_"
            throw
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
        $reuse = Read-Host "  Use existing ISO? (Y/n)"
        if ($reuse -ne 'n' -and $reuse -ne 'N') {
            Write-StepComplete "ISO ready (cached)"
            return $isoPath
        }
        Write-Status "Re-downloading..."
    }

    Write-Status "Source: $PveIsoUrl"
    Write-Status "Expected size: ~1.5 GB"
    Write-Host ""

    Download-WithProgress -Url $PveIsoUrl -Destination $isoPath -DisplayName "Proxmox VE $PveVersion ISO"

    if (-not (Test-Path $isoPath)) {
        Write-Err "Download failed - file not found"
        exit 1
    }

    $sizeMB = [math]::Round((Get-Item $isoPath).Length / 1MB)
    if ($sizeMB -lt 500) {
        Write-Err "Downloaded file is too small (${sizeMB} MB) - likely an error page, not an ISO"
        Remove-Item $isoPath -Force
        exit 1
    }

    Write-StepComplete "Downloaded ${sizeMB} MB"
    return $isoPath
}

# --- Installation Config ---

function Get-InstallConfig {
    Write-StepHeader "Configure PVE Installation"

    Write-Host "  Configure automated Proxmox installation settings." -ForegroundColor White
    Write-Host "  Press Enter to accept defaults shown in [brackets]." -ForegroundColor DarkGray
    Write-Host ""

    # Hostname
    if (-not $Hostname) {
        $input = Read-Host "  Hostname [pve]"
        $Hostname = if ($input) { $input } else { "pve" }
    }
    $script:Hostname = $Hostname

    # Domain
    if (-not $Domain) {
        $input = Read-Host "  Domain [local]"
        $Domain = if ($input) { $input } else { "local" }
    }
    $script:Domain = $Domain

    # Password
    if (-not $Password) {
        $securePass = Read-Host "  Root password [ChangeMe123!]" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
        $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $Password = if ($plainPass) { $plainPass } else { "ChangeMe123!" }
    }
    $script:Password = $Password

    # Filesystem
    if (-not $Filesystem) {
        Write-Host ""
        Write-Host "  Filesystem options:" -ForegroundColor White
        Write-Host "    1. ext4 (simple, reliable)" -ForegroundColor Gray
        Write-Host "    2. zfs  (snapshots, compression, RAID)" -ForegroundColor Gray
        $fsChoice = Read-Host "  Select filesystem [1]"
        $Filesystem = if ($fsChoice -eq "2") { "zfs" } else { "ext4" }
    }
    $script:Filesystem = $Filesystem

    # Clean previous PVE
    if (-not $CleanPreviousPve.IsPresent) {
        Write-Host ""
        $cleanChoice = Read-Host "  Clean up previous PVE installation if found? (y/N)"
        if ($cleanChoice -eq 'y' -or $cleanChoice -eq 'Y') {
            $script:CleanPreviousPve = $true
        }
        else {
            $script:CleanPreviousPve = $false
        }
    }
    else {
        $script:CleanPreviousPve = $true
    }

    Write-Host ""
    Write-Host "  Configuration Summary:" -ForegroundColor White
    Write-Host "  ----------------------" -ForegroundColor DarkGray
    Write-Host "    FQDN:        $($script:Hostname).$($script:Domain)" -ForegroundColor Cyan
    Write-Host "    Filesystem:  $($script:Filesystem)" -ForegroundColor Cyan
    Write-Host "    Network:     DHCP (configure static via Claude later)" -ForegroundColor Cyan
    Write-Host "    Clean old:   $(if ($script:CleanPreviousPve) { 'Yes' } else { 'No' })" -ForegroundColor Cyan
    Write-Host ""

    Write-StepComplete "Configuration ready"
}

# --- Answer File & Setup ---

function Create-AnswerToml {
    $cleanupCommands = ""
    if ($script:CleanPreviousPve) {
        $cleanupCommands = @"
    "echo '=== Cleaning previous PVE installation ==='",
    "for pool in `$(zpool list -H -o name 2>/dev/null); do echo Destroying pool `$pool; zpool destroy -f `$pool 2>/dev/null || true; done",
    "for disk in `$(lsblk -dno NAME | grep -v loop); do wipefs -af /dev/`$disk 2>/dev/null || true; done",
    "rm -rf /etc/pve 2>/dev/null || true",
    "rm -rf /var/lib/pve-cluster 2>/dev/null || true",
    "rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true",
    "echo '=== Cleanup complete ==='",
"@
    }

    $zfsConfig = ""
    if ($script:Filesystem -eq "zfs") {
        $zfsConfig = @"

[disk-setup]
filesystem = "zfs"
zfs.raid = "raid0"
zfs.compress = "on"
zfs.checksum = "on"
zfs.ashift = "12"
"@
    }
    else {
        $zfsConfig = @"

[disk-setup]
filesystem = "ext4"
"@
    }

    $answerToml = @"
# Proxmox VE Automated Installation Answer File
# Generated by PVE Installer USB Creator
# Edit this file on the 'proxmox-ais' USB partition if needed

[global]
keyboard = "en-us"
country = "us"
fqdn = "$($script:Hostname).$($script:Domain)"
mailto = "root@localhost"
timezone = "UTC"
root_password = "$($script:Password)"
root_ssh_keys = []

[network]
source = "from-dhcp"
$zfsConfig

[post-commands]
# Clean previous PVE + download and enable Claude Code auto-setup
post = [
$cleanupCommands    "curl -fsSL $SetupScriptUrl -o /root/first-boot-setup.sh",
    "chmod +x /root/first-boot-setup.sh",
    "cat > /etc/systemd/system/pve-claude-setup.service << 'SVCEOF'\n[Unit]\nDescription=PVE Claude Code Setup\nAfter=network-online.target\nWants=network-online.target\nConditionPathExists=!/var/lib/pve-claude-done\n\n[Service]\nType=oneshot\nExecStart=/root/first-boot-setup.sh --auto\nExecStartPost=/bin/touch /var/lib/pve-claude-done\nExecStartPost=/bin/systemctl disable pve-claude-setup.service\nTimeoutStartSec=600\n\n[Install]\nWantedBy=multi-user.target\nSVCEOF",
    "systemctl enable pve-claude-setup.service"
]
"@

    return $answerToml
}

# --- USB Writing ---

function Write-IsoToUSB {
    param(
        [string]$IsoPath,
        [PSCustomObject]$UsbDrive
    )

    Write-StepHeader "Write ISO to USB"

    $diskNumber = $UsbDrive.DiskNumber

    # Use diskpart for ALL disk prep - it handles offline/locked/bad-state disks
    # unlike Set-Disk which hangs on corrupted offline disks
    Write-Status "Preparing disk $diskNumber via diskpart..."
    $dpCommands = @"
select disk $diskNumber
online disk noerr
attributes disk clear readonly noerr
clean
offline disk noerr
"@
    $dpTempFile = [System.IO.Path]::GetTempFileName()
    $dpCommands | Out-File -FilePath $dpTempFile -Encoding ASCII
    $dpResult = & "$env:SystemRoot\System32\diskpart.exe" /s $dpTempFile 2>&1
    Remove-Item $dpTempFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Success "Disk cleaned and taken offline"

    Write-Status "Writing ISO to USB (DD mode)..."
    # Use FileStream with proper flags for raw device access
    $source = [System.IO.FileStream]::new($IsoPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $dest = [System.IO.FileStream]::new("\\.\PhysicalDrive$diskNumber", [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)

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
        $dest.Flush()
        $dest.Close()
        $source.Close()
    }

    Write-Host ""
    $writeElapsed = (Get-Date) - $writeStart
    $avgSpeed = [math]::Round($totalMB / $writeElapsed.TotalSeconds, 1)

    # Bring disk back online for answer partition creation
    Write-Status "Bringing disk back online..."
    $dpOnline = "select disk $diskNumber`nonline disk noerr"
    $dpTempFile = [System.IO.Path]::GetTempFileName()
    $dpOnline | Out-File -FilePath $dpTempFile -Encoding ASCII
    & "$env:SystemRoot\System32\diskpart.exe" /s $dpTempFile 2>&1 | Out-Null
    Remove-Item $dpTempFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-StepComplete "ISO written ($totalMB MB @ $avgSpeed MB/s)"
}

# --- Answer Partition ---

function Create-AnswerPartition {
    param(
        [PSCustomObject]$UsbDrive,
        [string]$AnswerToml
    )

    Write-StepHeader "Create Answer Partition"

    $diskNumber = $UsbDrive.DiskNumber

    Write-Status "Scanning USB disk for free space..."

    # Rescan disk to pick up the ISO's partition table
    Update-Disk -Number $diskNumber -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Get the disk's total size and used space
    $disk = Get-Disk -Number $diskNumber
    $usedBytes = 0
    $partitions = @(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)
    foreach ($p in $partitions) {
        $usedBytes += $p.Size
    }

    $freeBytes = $disk.Size - $usedBytes
    $freeMB = [math]::Round($freeBytes / 1MB)

    if ($freeMB -lt 10) {
        Write-Warn "Not enough free space for answer partition (${freeMB} MB free)"
        Write-Warn "Skipping answer partition - you can use manual installation"
        Write-Status "The answer.toml will be saved to the downloads folder instead"

        $answerPath = Join-Path $DownloadDir "answer.toml"
        $AnswerToml | Out-File -FilePath $answerPath -Encoding UTF8 -NoNewline
        Write-Success "answer.toml saved to: $answerPath"
        Write-StepComplete "Answer file saved (no partition)"
        return
    }

    Write-Status "Free space: ${freeMB} MB - creating answer partition..."

    try {
        # Create a small partition (32 MB is plenty for answer.toml)
        $partSize = [math]::Min(32MB, $freeBytes - 1MB)
        $newPart = New-Partition -DiskNumber $diskNumber -Size $partSize -AssignDriveLetter -ErrorAction Stop

        Start-Sleep -Seconds 2

        # Format as FAT32 with the label PVE automated installer looks for
        $driveLetter = $newPart.DriveLetter
        Format-Volume -DriveLetter $driveLetter -FileSystem FAT32 -NewFileSystemLabel "proxmox-ais" -Confirm:$false -ErrorAction Stop

        Write-Success "Answer partition created ($driveLetter`:, FAT32, proxmox-ais)"

        # Write answer.toml
        $answerPath = "${driveLetter}:\answer.toml"
        $AnswerToml | Out-File -FilePath $answerPath -Encoding UTF8 -NoNewline
        Write-Success "answer.toml written to $answerPath"

        # Also save a copy locally
        $localCopy = Join-Path $DownloadDir "answer.toml"
        $AnswerToml | Out-File -FilePath $localCopy -Encoding UTF8 -NoNewline

        # Write quick-start guide
        $quickStart = Get-QuickStartText
        $quickStart | Out-File -FilePath "${driveLetter}:\QUICK-START.txt" -Encoding UTF8
        Write-Success "QUICK-START.txt written"

        Write-StepComplete "Answer partition ready"
    }
    catch {
        Write-Warn "Could not create answer partition: $_"
        Write-Status "Saving answer.toml locally instead..."

        $answerPath = Join-Path $DownloadDir "answer.toml"
        $AnswerToml | Out-File -FilePath $answerPath -Encoding UTF8 -NoNewline
        Write-Success "answer.toml saved to: $answerPath"
        Write-StepComplete "Answer file saved (partition failed)"
    }
}

function Get-QuickStartText {
    return @"
PVE INSTALLER - QUICK START
============================

STEP 1: BOOT FROM USB
---------------------
Insert USB into your server and boot from it.
Press F12, F2, or DEL to access the boot menu.

STEP 2: INSTALL PROXMOX
-----------------------
Option A - Automated Installation (Recommended):
  - Select "Automated Installation" from boot menu
  - The installer will find answer.toml on this USB
  - Installation proceeds without further input

Option B - Manual Installation:
  - Select "Install Proxmox VE (Graphical)"
  - Follow the prompts manually

STEP 3: FIRST BOOT
------------------
After installation, the system will automatically:
  - Clean up previous PVE data (if configured)
  - Configure no-subscription repositories
  - Install Node.js and Claude Code
  - Start Claude in a tmux session

Just log in at the console and type: tm

STEP 4: USE CLAUDE
------------------
Claude is ready to help! Example commands:

  "Set my IP to 192.168.1.100/24 gateway 192.168.1.1"
  "Create a VM with Ubuntu 24.04"
  "Set up ZFS mirror on sdb and sdc"
  "Configure automated backups"

TROUBLESHOOTING
---------------
- Setup logs: /var/log/pve-claude-setup.log
- Service status: systemctl status pve-claude-setup
- Manual run: /root/first-boot-setup.sh
- Manual setup: curl -fsSL $SetupScriptUrl | bash
"@
}

# --- Completion ---

function Show-Completion {
    $totalElapsed = (Get-Date) - $script:OverallStartTime
    $totalTime = "{0:mm\:ss}" -f $totalElapsed

    Write-Host ""
    Write-Host "  ==========================================" -ForegroundColor Green
    Write-Host "    USB DRIVE READY!  (Total: $totalTime)" -ForegroundColor Green
    Write-Host "  ==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  WHAT'S ON THE USB:" -ForegroundColor Yellow
    Write-Host "    - Proxmox VE $PveVersion installer (bootable)" -ForegroundColor White
    Write-Host "    - answer.toml (automated install config)" -ForegroundColor White
    Write-Host "    - Claude Code auto-setup (runs on first boot)" -ForegroundColor White
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "    1. Plug USB into your server" -ForegroundColor White
    Write-Host "    2. Boot from USB (F12/F2/DEL for boot menu)" -ForegroundColor White
    Write-Host "    3. Select 'Automated Installation'" -ForegroundColor White
    Write-Host "    4. Wait for install + reboot" -ForegroundColor White
    Write-Host "    5. Log in and type: " -NoNewline -ForegroundColor White
    Write-Host "tm" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  CONFIGURATION:" -ForegroundColor Yellow
    Write-Host "    FQDN:     $($script:Hostname).$($script:Domain)" -ForegroundColor Gray
    Write-Host "    FS:       $($script:Filesystem)" -ForegroundColor Gray
    Write-Host "    Network:  DHCP (use Claude to set static IP)" -ForegroundColor Gray
    Write-Host ""

    if (Test-Path (Join-Path $DownloadDir "answer.toml")) {
        Write-Host "  EDIT CONFIG (if needed before booting):" -ForegroundColor Yellow
        Write-Host "    $(Join-Path $DownloadDir 'answer.toml')" -ForegroundColor Gray
        Write-Host ""
    }

    Write-Host "  MANUAL SETUP (if auto-setup doesn't run):" -ForegroundColor Yellow
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

    # Step 3: Configure installation
    Get-InstallConfig

    # Step 4: Write ISO to USB
    Write-IsoToUSB -IsoPath $script:isoPath -UsbDrive $script:selectedDrive

    # Step 5: Create answer partition with config
    $answerToml = Create-AnswerToml
    Create-AnswerPartition -UsbDrive $script:selectedDrive -AnswerToml $answerToml

    # Done
    Show-Completion
}

Main
