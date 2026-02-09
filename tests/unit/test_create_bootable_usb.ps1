#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Create-BootableUSB.ps1

.DESCRIPTION
    Tests the PowerShell USB creation script functions and logic.
    Run with: .\test_create_bootable_usb.ps1

.NOTES
    Uses Pester testing framework
#>

# Get paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$TargetScript = Join-Path $ProjectRoot "build\Create-BootableUSB.ps1"

# Check if Pester is available
if (-not (Get-Module -ListAvailable -Name Pester)) {
    Write-Host "Pester not installed. Install with: Install-Module Pester -Force" -ForegroundColor Yellow
    Write-Host "Running basic tests instead..." -ForegroundColor Yellow

    # Basic tests without Pester
    $tests = @{
        Passed = 0
        Failed = 0
    }

    function Test-Condition {
        param([string]$Name, [scriptblock]$Test)

        try {
            $result = & $Test
            if ($result) {
                Write-Host "[PASS] $Name" -ForegroundColor Green
                $script:tests.Passed++
            } else {
                Write-Host "[FAIL] $Name" -ForegroundColor Red
                $script:tests.Failed++
            }
        } catch {
            Write-Host "[FAIL] $Name - $_" -ForegroundColor Red
            $script:tests.Failed++
        }
    }

    Write-Host "`nRunning Create-BootableUSB.ps1 Tests`n" -ForegroundColor Cyan
    Write-Host "=" * 50

    # Test: Script exists
    Test-Condition "Script file exists" {
        Test-Path $TargetScript
    }

    # Test: Script has valid PowerShell syntax
    Test-Condition "Script has valid PowerShell syntax" {
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $TargetScript -Raw), [ref]$null)
        $true
    }

    # Test: Script defines required parameters
    Test-Condition "Script defines DriveLetter parameter" {
        (Get-Content $TargetScript -Raw) -match 'param\s*\(' -and
        (Get-Content $TargetScript -Raw) -match '\$DriveLetter'
    }

    # Test: Script defines PveVersion parameter
    Test-Condition "Script defines PveVersion parameter" {
        (Get-Content $TargetScript -Raw) -match '\$PveVersion'
    }

    # Test: Script has Test-Administrator function
    Test-Condition "Script has Test-Administrator function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Test-Administrator'
    }

    # Test: Script has Get-USBDrives function
    Test-Condition "Script has Get-USBDrives function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Get-USBDrives'
    }

    # Test: Script has Select-USBDrive function
    Test-Condition "Script has Select-USBDrive function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Select-USBDrive'
    }

    # Test: Script has Download-ProxmoxISO function
    Test-Condition "Script has Download-ProxmoxISO function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Download-ProxmoxISO'
    }

    # Test: Script has Write-IsoToUSB function
    Test-Condition "Script has Write-IsoToUSB function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Write-IsoToUSB'
    }

    # Test: Script has Create-AnswerPartition function
    Test-Condition "Script has Create-AnswerPartition function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Create-AnswerPartition'
    }

    # Test: Script references Proxmox ISO URL
    Test-Condition "Script has Proxmox ISO URL" {
        (Get-Content $TargetScript -Raw) -match 'proxmox\.com.*iso' -or
        (Get-Content $TargetScript -Raw) -match 'proxmox-ve.*\.iso'
    }

    # Test: Script checks for admin rights
    Test-Condition "Script checks for administrator rights" {
        (Get-Content $TargetScript -Raw) -match 'Administrator' -and
        (Get-Content $TargetScript -Raw) -match 'WindowsPrincipal'
    }

    # Test: Script has disk operations
    Test-Condition "Script has disk formatting logic" {
        (Get-Content $TargetScript -Raw) -match 'Format-Volume' -or
        (Get-Content $TargetScript -Raw) -match 'Clear-Disk'
    }

    # Test: Script generates answer.toml
    Test-Condition "Script generates answer.toml" {
        (Get-Content $TargetScript -Raw) -match 'answer\.toml' -and
        (Get-Content $TargetScript -Raw) -match 'post-commands'
    }

    # Test: Script has Get-InstallConfig function
    Test-Condition "Script has Get-InstallConfig function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Get-InstallConfig'
    }

    # Test: Script has Show-Completion function
    Test-Condition "Script has Show-Completion function" {
        (Get-Content $TargetScript -Raw) -match 'function\s+Show-Completion'
    }

    # Test: Script shows next steps
    Test-Condition "Script shows next steps to user" {
        (Get-Content $TargetScript -Raw) -match 'NEXT STEPS'
    }

    Write-Host "`n" + "=" * 50
    Write-Host "Results: $($tests.Passed) passed, $($tests.Failed) failed" -ForegroundColor $(if ($tests.Failed -eq 0) { "Green" } else { "Red" })

    exit $(if ($tests.Failed -eq 0) { 0 } else { 1 })
}

# If Pester is available, use it
Describe "Create-BootableUSB.ps1" {

    BeforeAll {
        $script:TargetScript = $TargetScript
    }

    Context "Script Structure" {

        It "Script file exists" {
            Test-Path $script:TargetScript | Should -Be $true
        }

        It "Script has valid PowerShell syntax" {
            { [System.Management.Automation.PSParser]::Tokenize((Get-Content $script:TargetScript -Raw), [ref]$null) } | Should -Not -Throw
        }

        It "Script has required parameters" {
            $content = Get-Content $script:TargetScript -Raw
            $content | Should -Match '\$DriveLetter'
            $content | Should -Match '\$PveVersion'
            $content | Should -Match '\$SkipDownload'
            $content | Should -Match '\$Hostname'
            $content | Should -Match '\$Filesystem'
            $content | Should -Match '\$CleanPreviousPve'
        }
    }

    Context "Required Functions" {

        BeforeAll {
            $script:Content = Get-Content $script:TargetScript -Raw
        }

        It "Has Test-Administrator function" {
            $script:Content | Should -Match 'function\s+Test-Administrator'
        }

        It "Has Get-USBDrives function" {
            $script:Content | Should -Match 'function\s+Get-USBDrives'
        }

        It "Has Select-USBDrive function" {
            $script:Content | Should -Match 'function\s+Select-USBDrive'
        }

        It "Has Download-ProxmoxISO function" {
            $script:Content | Should -Match 'function\s+Download-ProxmoxISO'
        }

        It "Has Write-IsoToUSB function" {
            $script:Content | Should -Match 'function\s+Write-IsoToUSB'
        }

        It "Has Create-AnswerPartition function" {
            $script:Content | Should -Match 'function\s+Create-AnswerPartition'
        }

        It "Has Create-AnswerToml function" {
            $script:Content | Should -Match 'function\s+Create-AnswerToml'
        }

        It "Has Get-InstallConfig function" {
            $script:Content | Should -Match 'function\s+Get-InstallConfig'
        }

        It "Has Show-Completion function" {
            $script:Content | Should -Match 'function\s+Show-Completion'
        }
    }

    Context "Security Checks" {

        BeforeAll {
            $script:Content = Get-Content $script:TargetScript -Raw
        }

        It "Checks for administrator rights" {
            $script:Content | Should -Match 'Administrator'
            $script:Content | Should -Match 'WindowsPrincipal'
        }

        It "Confirms before formatting disk" {
            $script:Content | Should -Match 'YES'
            $script:Content | Should -Match 'confirm'
        }

        It "Warns about data loss" {
            $script:Content | Should -Match 'ERASE|WARNING'
        }
    }

    Context "Proxmox Integration" {

        BeforeAll {
            $script:Content = Get-Content $script:TargetScript -Raw
        }

        It "References Proxmox ISO" {
            $script:Content | Should -Match 'proxmox-ve.*\.iso'
        }

        It "Downloads from official source" {
            $script:Content | Should -Match 'proxmox\.com'
        }

        It "Generates answer.toml" {
            $script:Content | Should -Match 'answer\.toml'
            $script:Content | Should -Match 'post-commands'
        }

        It "Supports PVE cleanup for reinstall" {
            $script:Content | Should -Match 'CleanPreviousPve'
            $script:Content | Should -Match 'zpool'
            $script:Content | Should -Match 'wipefs'
        }
    }

    Context "USB Operations" {

        BeforeAll {
            $script:Content = Get-Content $script:TargetScript -Raw
        }

        It "Detects USB drives" {
            $script:Content | Should -Match 'USB'
            $script:Content | Should -Match 'Get-Disk|Get-WmiObject'
        }

        It "Clears the disk before writing" {
            $script:Content | Should -Match 'Clear-Disk'
        }

        It "Writes ISO directly to disk" {
            $script:Content | Should -Match 'PhysicalDrive'
            $script:Content | Should -Match 'OpenWrite'
        }

        It "Creates answer partition" {
            $script:Content | Should -Match 'New-Partition'
            $script:Content | Should -Match 'proxmox-ais'
            $script:Content | Should -Match 'Format-Volume'
        }
    }
}
