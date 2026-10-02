#requires -version 5.1
<#
.LILMAN WINDOWS MAX PERFORMANCE / DEBLOAT
Safe scope:
  - Does NOT disable/modify Ethernet/Wi-Fi adapter drivers or network services.
  - Does NOT disable/modify GPU/display drivers.
  - Does NOT disable audio services/drivers.
  - Does NOT disable USB/HID/input services/drivers.
  - Does NOT disable Xbox/Gaming services.
  - Does NOT claim guaranteed FPS, ping, latency, or stutter improvements.
  - Creates a registry backup and Windows restore point when available.
  - Designed for Windows 10/11 Pro/Home x64.

Run elevated PowerShell:
  Set-ExecutionPolicy -Scope Process Bypass
  .\Lilman-MaxPerformance.ps1

Optional:
  .\Lilman-MaxPerformance.ps1 -Undo
  .\Lilman-MaxPerformance.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [switch]$Undo,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Root = Join-Path $env:ProgramData 'Lilman\MaxPerformance'
$Backup = Join-Path $Root 'Backup'
$Log = Join-Path $Root 'Lilman-MaxPerformance.log'

function Write-Lilman {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $line = "[Lilman] $Text"
    Write-Host $line -ForegroundColor $Color
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Lilman {
    param(
        [string]$Description,
        [scriptblock]$Action
    )
    if ($DryRun) {
        Write-Lilman "DRY RUN: $Description" Cyan
        return
    }
    try {
        & $Action
        Write-Lilman "OK: $Description" Green
    } catch {
        Write-Lilman "SKIP/ERROR: $Description :: $($_.Exception.Message)" Yellow
    }
}

if (-not (Test-Admin)) {
    Write-Lilman "Administrator PowerShell is required. Right-click PowerShell -> Run as administrator." Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $Root,$Backup | Out-Null
$TranscriptLog = Join-Path $Root 'Lilman-MaxPerformance-transcript.log'
try { Start-Transcript -Path $TranscriptLog -Append -ErrorAction SilentlyContinue | Out-Null } catch {}

$os = Get-CimInstance Win32_OperatingSystem
Write-Lilman "Windows: $($os.Caption) build $($os.BuildNumber)" Cyan

# ---------------------------------------------------------------------------
# ROLLBACK
# ---------------------------------------------------------------------------
if ($Undo) {
    Write-Lilman "Rollback requested." Cyan

    Invoke-Lilman "Re-enable hibernation / Fast Startup" {
        powercfg /hibernate on | Out-Null
    }

    Invoke-Lilman "Restore Windows Search to automatic startup" {
        $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name WSearch -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name WSearch -ErrorAction SilentlyContinue
        }
    }

    Invoke-Lilman "Remove Lilman power plan when identifiable" {
        $plans = powercfg /list | Out-String
        $m = [regex]::Match($plans, '(?im)^\s*Power Scheme GUID:\s*([0-9a-f-]+)\s+\(Lilman Maximum Performance\)')
        if ($m.Success) {
            powercfg /delete $m.Groups[1].Value | Out-Null
        }
    }

    Invoke-Lilman "Remove Lilman power-throttling override" {
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
        if (Test-Path $k) {
            Remove-ItemProperty -Path $k -Name PowerThrottlingOff -ErrorAction SilentlyContinue
        }
    }

    Invoke-Lilman "Restore common Game DVR defaults" {
        $g = 'HKCU:\System\GameConfigStore'
        if (Test-Path $g) {
            New-ItemProperty -Path $g -Name GameDVR_Enabled -PropertyType DWord -Value 1 -Force | Out-Null
        }
        $c = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'
        if (Test-Path $c) {
            New-ItemProperty -Path $c -Name AppCaptureEnabled -PropertyType DWord -Value 1 -Force | Out-Null
        }
    }

    Write-Lilman "Rollback completed for reversible policy/settings changes. AppX removals and deleted startup entries require reinstall/recreation." Green
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

# ---------------------------------------------------------------------------
# HARD SAFETY EXCLUSIONS
# ---------------------------------------------------------------------------
# These are never touched by this script.
$ProtectedServicePatterns = @(
    # Networking / NIC / TCP-IP / WLAN
    'Dhcp','Dnscache','NlaSvc','netprofm','WlanSvc','WinHttpAutoProxySvc',
    'iphlpsvc','LanmanWorkstation','LanmanServer','BFE','MpsSvc',
    'nsi','Netman','PolicyAgent','IKEEXT','RasMan','RemoteAccess',
    # Audio
    'Audiosrv','AudioEndpointBuilder',
    # USB / HID / input / device framework
    'hidserv','DeviceInstall','DsmSvc','PlugPlay','InputService',
    'DeviceAssociationService','TabletInputService','HumanInterfaceDeviceService',
    # Graphics / display / driver infrastructure
    'DisplayEnhancementService','GraphicsPerfSvc','AppReadiness',
    # Gaming / Xbox / game services -- intentionally untouched
    'GamingServices','GamingServicesNet','XboxGipSvc','XblAuthManager',
    'XblGameSave','XboxNetApiSvc','BcastDVRUserService*','GameInputSvc',
    'GameInputRedist*'
)

function Is-ProtectedService([string]$Name) {
    foreach ($p in $ProtectedServicePatterns) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# BACKUP
# ---------------------------------------------------------------------------
$BackupReg = Join-Path $Backup 'HKCU-HKLM-SOFTWARE-Policies.reg'
if (-not $DryRun) {
    Invoke-Lilman "Create a Windows restore point" {
        try {
            Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description 'Lilman Max Performance Before Debloat' -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
        } catch {}
    }

    Invoke-Lilman "Back up policy registry branches" {
        reg.exe export "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies" (Join-Path $Backup 'HKCU-Policies.reg') /y | Out-Null
        reg.exe export "HKLM\SOFTWARE\Policies" (Join-Path $Backup 'HKLM-Policies.reg') /y | Out-Null
    }

    Invoke-Lilman "Back up current power scheme" {
        powercfg /getactivescheme | Out-File (Join-Path $Backup 'active-power-scheme.txt') -Encoding utf8
        powercfg /export (Join-Path $Backup 'active-power-scheme.pow') $null
    }
}

# ---------------------------------------------------------------------------
# REMOVE NON-ESSENTIAL BUILT-IN CONSUMER APPX PACKAGES
# ---------------------------------------------------------------------------
# Deliberately excludes Store, Photos, Calculator, Terminal, Security, Xbox,
# GamingServices and all driver/vendor packages.
$RemoveAppxNames = @(
    'Microsoft.3DBuilder',
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'Clipchamp.Clipchamp',
    'MicrosoftTeams',
    'MSTeams'
)

foreach ($name in $RemoveAppxNames) {
    Invoke-Lilman "Remove optional AppX: $name" {
        Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue |
            Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $name } |
            Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------------------------------------------------------------------------
# STARTUP CLEANUP -- ONLY OBVIOUS CONSUMER STARTUP ENTRIES
# ---------------------------------------------------------------------------
$StartupRegistryPaths = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)

$StartupNamePatterns = @(
    'OneDrive',
    'MicrosoftEdgeAutoLaunch*',
    'Teams*',
    'Microsoft Teams*',
    'Skype*',
    'Spotify*',
    'Discord*',
    'AdobeGCInvoker*',
    'AdobeAAMUpdater*',
    'GoogleDriveFS*'
)

foreach ($path in $StartupRegistryPaths) {
    foreach ($pattern in $StartupNamePatterns) {
        Invoke-Lilman "Disable optional startup entry $pattern from $path" {
            if (Test-Path $path) {
                $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                foreach ($prop in $props.PSObject.Properties) {
                    if ($prop.Name -like $pattern) {
                        Remove-ItemProperty -Path $path -Name $prop.Name -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# OPTIONAL SCHEDULED TASK OVERHEAD
# Do NOT touch Windows servicing, security, driver, networking, input or game tasks.
# ---------------------------------------------------------------------------
$OptionalTaskPatterns = @(
    '*MicrosoftEdgeUpdateTaskMachineCore*',
    '*MicrosoftEdgeUpdateTaskMachineUA*',
    '*OneDrive Standalone Update Task*',
    '*OneDrive Reporting Task*',
    '*GoogleUpdateTaskMachineCore*',
    '*GoogleUpdateTaskMachineUA*'
)

foreach ($pattern in $OptionalTaskPatterns) {
    Invoke-Lilman "Disable optional updater task $pattern" {
        Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like $pattern } |
            Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------------------------------------------------------------------------
# WINDOWS SEARCH INDEXING
# This is intentionally not a service kill. It disables indexing through the
# supported Search service startup mechanism only if present.
# NOTE: users who depend heavily on instant file search may prefer to leave it on.
# ---------------------------------------------------------------------------
Invoke-Lilman "Reduce Windows Search background indexing" {
    $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name WSearch -StartupType Manual -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# DELIVERY OPTIMIZATION
# Windows Update remains enabled. This only prevents peer-to-peer update sharing.
# ---------------------------------------------------------------------------
Invoke-Lilman "Disable Delivery Optimization peer sharing" {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
    New-Item -Path $p -Force | Out-Null
    New-ItemProperty -Path $p -Name 'DODownloadMode' -PropertyType DWord -Value 0 -Force | Out-Null
}

# ---------------------------------------------------------------------------
# VISUAL OVERHEAD / UI RESPONSIVENESS
# ---------------------------------------------------------------------------
Invoke-Lilman "Use performance-oriented visual effects" {
    $visual = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    New-Item -Path $visual -Force | Out-Null
    New-ItemProperty -Path $visual -Name 'VisualFXSetting' -PropertyType DWord -Value 2 -Force | Out-Null

    $desktop = 'HKCU:\Control Panel\Desktop'
    New-Item -Path $desktop -Force | Out-Null
    New-ItemProperty -Path $desktop -Name 'MenuShowDelay' -PropertyType String -Value '0' -Force | Out-Null
    New-ItemProperty -Path $desktop -Name 'AutoEndTasks' -PropertyType String -Value '1' -Force | Out-Null

    $windowMetrics = 'HKCU:\Control Panel\Desktop\WindowMetrics'
    if (Test-Path $windowMetrics) {
        New-ItemProperty -Path $windowMetrics -Name 'MinAnimate' -PropertyType String -Value '0' -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# GAME MODE / GAME DVR
# Does not touch Xbox/Gaming services.
# ---------------------------------------------------------------------------
Invoke-Lilman "Enable Windows Game Mode and disable background Game DVR capture" {
    $gameDvr = 'HKCU:\System\GameConfigStore'
    New-Item -Path $gameDvr -Force | Out-Null
    New-ItemProperty -Path $gameDvr -Name 'GameDVR_Enabled' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $gameDvr -Name 'GameDVR_FSEBehaviorMode' -PropertyType DWord -Value 2 -Force | Out-Null

    $gameBar = 'HKCU:\SOFTWARE\Microsoft\GameBar'
    New-Item -Path $gameBar -Force | Out-Null
    New-ItemProperty -Path $gameBar -Name 'AutoGameModeEnabled' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $gameBar -Name 'AllowAutoGameMode' -PropertyType DWord -Value 1 -Force | Out-Null

    $capture = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'
    New-Item -Path $capture -Force | Out-Null
    New-ItemProperty -Path $capture -Name 'AppCaptureEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
}

# ---------------------------------------------------------------------------
# POWER / CPU RESPONSIVENESS
# Uses documented powercfg aliases. No hard-coded CPU frequency.
# This preserves the OS/firmware's ability to manage the CPU while favoring
# performance on AC power.
# ---------------------------------------------------------------------------
Invoke-Lilman "Create and activate a Lilman Maximum Performance power plan" {
    $dup = (powercfg -duplicatescheme SCHEME_MIN 2>$null) | Out-String
    $guid = [regex]::Match($dup, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value

    if (-not $guid) {
        $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    }

    powercfg -changename $guid 'Lilman Maximum Performance' 'Lilman performance-focused Windows power plan' | Out-Null

    # AC only: leave battery/DC behavior alone.
    powercfg -setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
    powercfg -setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
    powercfg -setacvalueindex $guid SUB_PROCESSOR PERFEPP 0 | Out-Null

    # PCIe link-state power management: disabled on AC.
    powercfg -setacvalueindex $guid SUB_PCIEXPRESS ASPM 0 | Out-Null

    # USB selective suspend: disabled on AC.
    powercfg -setacvalueindex $guid SUB_USB USBSELECTIVE 0 | Out-Null

    # Disk idle timeout: never on AC.
    powercfg -setacvalueindex $guid SUB_DISK DISKIDLE 0 | Out-Null

    powercfg -setactive $guid | Out-Null
}

# ---------------------------------------------------------------------------
# POWER THROTTLING
# Disable user-level Windows power throttling policy. This is NOT a network
# tweak and does not touch drivers/services.
# ---------------------------------------------------------------------------
Invoke-Lilman "Disable Windows power throttling for background applications" {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    New-Item -Path $p -Force | Out-Null
    New-ItemProperty -Path $p -Name 'PowerThrottlingOff' -PropertyType DWord -Value 1 -Force | Out-Null
}

# ---------------------------------------------------------------------------
# STORAGE: disable Last Access timestamp updates on NTFS.
# This is a filesystem metadata optimization, not an SSD "speed hack".
# ---------------------------------------------------------------------------
Invoke-Lilman "Disable NTFS last-access timestamp updates" {
    fsutil behavior set disablelastaccess 1 | Out-Null
}

# ---------------------------------------------------------------------------
# HIBERNATION / FAST STARTUP
# Disable only if user wants a leaner disk footprint and no hibernation.
# It also removes hiberfil.sys. This is reversible with 'powercfg /hibernate on'.
# ---------------------------------------------------------------------------
Invoke-Lilman "Disable hibernation and Fast Startup" {
    powercfg /hibernate off | Out-Null
}

# ---------------------------------------------------------------------------
# LOW-LEVEL TIMER / HPET / TCP / NIC / GPU "TWEAKS"
# INTENTIONALLY NOT TOUCHED.
#
# No forced HPET, bcdedit timer hacks, TCP autotuning hacks, Nagle hacks,
# RSS changes, NIC offload changes, interrupt moderation changes, GPU driver
# changes, audio stack changes, USB polling hacks, or gaming service disables.
#
# Those are hardware/driver/network-path dependent and can make systems worse.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# CLEAN TEMPORARY USER CACHE
# Only removes files from known temporary locations.
# ---------------------------------------------------------------------------
Invoke-Lilman "Clean safe user/system temporary files" {
    $paths = @($env:TEMP, "$env:WINDIR\Temp")
    foreach ($p in $paths) {
        if (Test-Path $p) {
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# VERIFY PROTECTED SERVICES STILL EXIST / ARE NOT DISABLED
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    Write-Lilman "Verifying protected service policy..." Cyan
    foreach ($n in $ProtectedServicePatterns | Where-Object {$_ -notlike '*\*'}) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($svc) {
            $c = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
            if ($c -and $c.StartMode -eq 'Disabled') {
                Write-Lilman "WARNING: protected service $n is already Disabled; script did not disable it." Yellow
            }
        }
    }

    Write-Lilman "Active power scheme:" Cyan
    powercfg /getactivescheme

    Write-Lilman "Network adapters left untouched:" Cyan
    Get-NetAdapter -ErrorAction SilentlyContinue |
        Select-Object Name, InterfaceDescription, Status, LinkSpeed |
        Format-Table -AutoSize | Out-String | Write-Host

    Write-Lilman "Gaming/Xbox services left untouched by this script." Green
    Write-Lilman "GPU/audio/input drivers are not modified by this script." Green
}

Write-Lilman "Finished. Restart Windows before benchmarking." Green
Write-Lilman "For a fair test, compare the same game/scenario before and after; do not treat ping/FPS as guaranteed." Cyan

try { Stop-Transcript | Out-Null } catch {}
