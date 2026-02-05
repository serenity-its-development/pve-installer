<#
.SYNOPSIS
    Build PVE Installer USB on Windows 11

.DESCRIPTION
    This script creates a bootable USB drive with Debian Live + Claude Code
    for installing Proxmox VE. It downloads a Debian Live ISO and customizes
    it with the necessary tools.

.PARAMETER UsbDrive
    The USB drive letter (e.g., "E:")

.PARAMETER SkipDownload
    Skip downloading the Debian ISO if it already exists

.EXAMPLE
    .\build-usb.ps1 -UsbDrive "E:"

.NOTES
    Requires Administrator privileges
    Requires Windows 11 or Windows 10 with WSL2
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$UsbDrive,

    [switch]$SkipDownload,

    [switch]$UseWSL
)

$ErrorActionPreference = "Stop"

# Configuration
$DebianVersion = "12.8.0"
$DebianCodename = "bookworm"
$IsoUrl = "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-$DebianVersion-amd64-standard.iso"
$IsoFileName = "debian-live-$DebianVersion-amd64-standard.iso"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DownloadDir = Join-Path $ScriptDir "download"
$OutputDir = Join-Path $ScriptDir "output"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $colors = @{
        "INFO" = "Green"
        "WARN" = "Yellow"
        "ERROR" = "Red"
        "STEP" = "Cyan"
    }

    $color = $colors[$Level]
    if (-not $color) { $color = "White" }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UsbDrives {
    Get-WmiObject Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' } | ForEach-Object {
        $disk = $_
        $partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($disk.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition"
        foreach ($partition in $partitions) {
            $logicalDisks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($partition.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition"
            foreach ($logicalDisk in $logicalDisks) {
                [PSCustomObject]@{
                    DriveLetter = $logicalDisk.DeviceID
                    DiskNumber = $disk.Index
                    Size = [math]::Round($disk.Size / 1GB, 2)
                    Model = $disk.Model
                }
            }
        }
    }
}

function Select-UsbDrive {
    Write-Log "Detecting USB drives..." "STEP"

    $usbDrives = Get-UsbDrives

    if ($usbDrives.Count -eq 0) {
        Write-Log "No USB drives detected. Please insert a USB drive and try again." "ERROR"
        exit 1
    }

    Write-Host "`nAvailable USB Drives:"
    Write-Host "====================="
    $i = 1
    foreach ($drive in $usbDrives) {
        Write-Host "$i. $($drive.DriveLetter) - $($drive.Model) ($($drive.Size) GB)"
        $i++
    }

    Write-Host ""
    $selection = Read-Host "Select USB drive (1-$($usbDrives.Count))"

    $index = [int]$selection - 1
    if ($index -lt 0 -or $index -ge $usbDrives.Count) {
        Write-Log "Invalid selection" "ERROR"
        exit 1
    }

    return $usbDrives[$index]
}

function Download-DebianIso {
    Write-Log "Downloading Debian Live ISO..." "STEP"

    if (-not (Test-Path $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir | Out-Null
    }

    $isoPath = Join-Path $DownloadDir $IsoFileName

    if ((Test-Path $isoPath) -and $SkipDownload) {
        Write-Log "Using existing ISO: $isoPath"
        return $isoPath
    }

    Write-Log "Downloading from: $IsoUrl"
    Write-Log "This may take a while..."

    # Use BITS for better download handling
    try {
        Start-BitsTransfer -Source $IsoUrl -Destination $isoPath -DisplayName "Downloading Debian ISO"
    } catch {
        Write-Log "BITS transfer failed, trying Invoke-WebRequest..." "WARN"
        Invoke-WebRequest -Uri $IsoUrl -OutFile $isoPath -UseBasicParsing
    }

    Write-Log "Download complete: $isoPath"
    return $isoPath
}

function Write-IsoToUsb {
    param(
        [string]$IsoPath,
        [PSCustomObject]$UsbDrive
    )

    Write-Log "Writing ISO to USB drive $($UsbDrive.DriveLetter)..." "STEP"

    $diskNumber = $UsbDrive.DiskNumber

    Write-Host ""
    Write-Host "WARNING: This will ERASE ALL DATA on $($UsbDrive.DriveLetter) ($($UsbDrive.Model))" -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Type 'YES' to continue"

    if ($confirm -ne "YES") {
        Write-Log "Aborted by user" "WARN"
        exit 0
    }

    # Create diskpart script
    $diskpartScript = @"
select disk $diskNumber
clean
create partition primary
select partition 1
active
format fs=fat32 quick label=PVEINSTALL
assign letter=P
exit
"@

    $diskpartFile = Join-Path $env:TEMP "diskpart_script.txt"
    $diskpartScript | Out-File -FilePath $diskpartFile -Encoding ASCII

    Write-Log "Formatting USB drive..."
    Start-Process -FilePath "diskpart.exe" -ArgumentList "/s `"$diskpartFile`"" -Wait -NoNewWindow

    # Mount the ISO
    Write-Log "Mounting ISO..."
    $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $isoDriveLetter = ($mountResult | Get-Volume).DriveLetter

    # Copy files
    Write-Log "Copying files to USB (this may take several minutes)..."
    $source = "$($isoDriveLetter):\"
    $destination = "P:\"

    # Use robocopy for better performance
    robocopy $source $destination /E /R:3 /W:5 /MT:8 /NP

    # Copy our custom scripts
    Write-Log "Adding PVE installer scripts..."
    $customDir = "P:\pve-installer"
    New-Item -ItemType Directory -Path $customDir -Force | Out-Null

    Copy-Item -Path "$ProjectRoot\installer\*" -Destination "$customDir\installer\" -Recurse -Force
    Copy-Item -Path "$ProjectRoot\post-install\*" -Destination "$customDir\post-install\" -Recurse -Force
    Copy-Item -Path "$ProjectRoot\config\*" -Destination "$customDir\config\" -Recurse -Force

    # Create autorun script for live environment
    $autorunScript = @"
#!/bin/bash
# PVE Installer Auto-setup
# This runs when the live system boots

# Copy installer scripts to /root
cp -r /run/live/medium/pve-installer/* /root/ 2>/dev/null || true

# Display welcome message
cat << 'EOF'
===============================================================================
                     PVE INSTALLER - Claude Code Edition
===============================================================================

Scripts have been copied to /root/

To install Proxmox:
  1. Run 'claude' to start Claude Code CLI
  2. Or run '/root/installer/install-proxmox.sh' directly

===============================================================================
EOF
"@

    $autorunScript | Out-File -FilePath "P:\pve-installer\setup.sh" -Encoding UTF8 -NoNewline

    # Unmount ISO
    Write-Log "Cleaning up..."
    Dismount-DiskImage -ImagePath $IsoPath

    Remove-Item $diskpartFile -Force

    Write-Log "USB drive created successfully!" "INFO"
}

function Build-WithWSL {
    param([string]$IsoPath)

    Write-Log "Building with WSL..." "STEP"

    # Check if WSL is available
    $wslCheck = wsl --status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WSL is not available. Please install WSL2." "ERROR"
        Write-Log "Run: wsl --install" "INFO"
        exit 1
    }

    # Convert Windows path to WSL path
    $wslProjectRoot = wsl wslpath -u "'$ProjectRoot'"
    $wslOutputDir = wsl wslpath -u "'$OutputDir'"

    # Run the Linux build script in WSL
    Write-Log "Running Linux build script in WSL..."
    Write-Log "This requires sudo access in WSL"

    wsl -u root bash -c "cd $wslProjectRoot && ./build/build-usb.sh"

    if ($LASTEXITCODE -eq 0) {
        Write-Log "Build complete! ISO available at: $OutputDir\pve-installer.iso"
    } else {
        Write-Log "Build failed" "ERROR"
        exit 1
    }
}

function Show-Help {
    Write-Host @"

PVE Installer USB Builder for Windows
======================================

This script creates a bootable USB drive for installing Proxmox VE.

METHODS:

1. Direct USB Write (Default)
   Downloads Debian Live ISO and writes directly to USB with custom scripts.
   Quick but less customized.

   Usage: .\build-usb.ps1 -UsbDrive "E:"

2. WSL Build (Full Customization)
   Uses WSL to run the full Linux build process, creating a fully
   customized ISO with Claude Code pre-installed.

   Usage: .\build-usb.ps1 -UseWSL

OPTIONS:

  -UsbDrive     Target USB drive letter (e.g., "E:")
  -SkipDownload Skip downloading ISO if already exists
  -UseWSL       Use WSL for full customization build

REQUIREMENTS:

  - Windows 11 or Windows 10
  - Administrator privileges
  - For WSL build: WSL2 with Debian/Ubuntu installed

"@
}

# Main
function Main {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  PVE Installer USB Builder (Windows)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    # Check admin rights
    if (-not (Test-Administrator)) {
        Write-Log "This script requires Administrator privileges" "ERROR"
        Write-Log "Please run PowerShell as Administrator" "INFO"
        exit 1
    }

    # Create output directory
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }

    if ($UseWSL) {
        Build-WithWSL
    } else {
        # Download Debian ISO
        $isoPath = Download-DebianIso

        # Select or use specified USB drive
        if ($UsbDrive) {
            $selectedDrive = Get-UsbDrives | Where-Object { $_.DriveLetter -eq $UsbDrive }
            if (-not $selectedDrive) {
                Write-Log "USB drive $UsbDrive not found" "ERROR"
                exit 1
            }
        } else {
            $selectedDrive = Select-UsbDrive
        }

        # Write to USB
        Write-IsoToUsb -IsoPath $isoPath -UsbDrive $selectedDrive

        Write-Host ""
        Write-Log "USB drive is ready!" "INFO"
        Write-Host ""
        Write-Host "Next steps:"
        Write-Host "  1. Boot your server from this USB drive"
        Write-Host "  2. Once booted, run: /pve-installer/setup.sh"
        Write-Host "  3. Then install Node.js and Claude Code manually, or run the installer script"
        Write-Host ""
    }
}

# Run main or show help
if ($args -contains "-h" -or $args -contains "--help" -or $args -contains "help") {
    Show-Help
} else {
    Main
}
