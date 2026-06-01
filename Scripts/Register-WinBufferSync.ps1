#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    One-time installer for the WinBufferSync scheduled task.
.DESCRIPTION
    Run this script ONCE as Administrator on the server.
    It will:
      1. Create C:\Scripts\WinBufferSync and copy the sync script there (if not already present)
      2. Create C:\Logs\WinBufferSync\ for log output
      3. Register the Windows Event Log source 'WinBufferSync'
      4. Create the Task Scheduler task 'WinBufferSync' that runs every 5 minutes
         under a dedicated service account (or SYSTEM if no account is specified)

    To remove everything cleanly, run with -Uninstall.
#>
param(
    # Service account to run the task under.
    # Best practice: create a dedicated gMSA (Highly Recommended) or standard service account.
    # Leave blank to use SYSTEM (simpler but less auditable).
    [string] $RunAsAccount = 'SYSTEM',

    # Only required when RunAsAccount is NOT SYSTEM
    [string] $RunAsPassword = '',

    # Pass -Uninstall to remove the task and Event Log source
    [switch] $Uninstall
)

$TaskName   = 'WinBufferSync'
$TaskPath   = '\IT Infrastructure\'
$ScriptDir  = 'C:\Scripts\WinBufferSync'
$ScriptPath = Join-Path $ScriptDir 'WinBufferSync.ps1'
$LogDir     = 'C:\Logs\WinBufferSync'
$EventSource = 'WinBufferSync'

# ─── Uninstall path ───────────────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host "Unregistering task '$TaskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        Remove-EventLog -Source $EventSource -ErrorAction SilentlyContinue
        Write-Host "Removed Event Log source '$EventSource'." -ForegroundColor Yellow
    }
    Write-Host "Done. Script files at $ScriptDir and logs at $LogDir were NOT deleted." -ForegroundColor Green
    Write-Host "Remove them manually if no longer needed." -ForegroundColor Green
    exit 0
}

# ─── Pre-flight checks ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "WinBufferSync — Task Installer" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan

# Check that the sync script exists at the source location
$sourceScript = Join-Path $PSScriptRoot 'WinBufferSync.ps1'
if (-not (Test-Path $sourceScript)) {
    Write-Error "Cannot find WinBufferSync.ps1 next to this installer script at: $PSScriptRoot"
    Write-Error "Place both scripts in the same folder before running this installer."
    exit 1
}

# ─── Create directories ───────────────────────────────────────────────────────
foreach ($dir in @($ScriptDir, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created: $dir" -ForegroundColor Green
    } else {
        Write-Host "Exists:  $dir" -ForegroundColor Gray
    }
}

# Copy the sync script into place
if ($sourceScript -ne $ScriptPath) { Copy-Item -Path $sourceScript -Destination $ScriptPath -Force }
Write-Host "Deployed: $ScriptPath" -ForegroundColor Green

# ─── Register Event Log source ────────────────────────────────────────────────
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    New-EventLog -LogName 'Application' -Source $EventSource
    Write-Host "Registered Event Log source: $EventSource" -ForegroundColor Green
} else {
    Write-Host "Event Log source already registered: $EventSource" -ForegroundColor Gray
}

# ─── Build the scheduled task ─────────────────────────────────────────────────
# Action: run PowerShell with the sync script
$psExe   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs  = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
$action  = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs

# Trigger: repeat every 5 minutes, indefinitely, starting at midnight today
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) `
                                    -Once `
                                    -At (Get-Date -Hour 0 -Minute 0 -Second 0 -Millisecond 0) `
                                    

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit      (New-TimeSpan -Minutes 4) `
    -MultipleInstances       IgnoreNew `
    -RestartCount            0 `
    -StartWhenAvailable      `
    -RunOnlyIfNetworkAvailable `
    -Compatibility           Win8

# Principal (who runs it)
if ($RunAsAccount -eq 'SYSTEM') {
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
                                            -LogonType ServiceAccount `
                                            -RunLevel Highest
} else {
    $principal = New-ScheduledTaskPrincipal -UserId $RunAsAccount `
                                            -LogonType Password `
                                            -RunLevel Highest
}

# Description
$taskDesc = @"
Copies files from buffer folders to their destinations. Locked files are skipped and retried on the next cycle.
Logs: $LogDir  |  Event Log source: $EventSource
Managed by: IT Infrastructure
"@

# Register (or overwrite if already exists)
$existingTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "Task already exists — updating..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
}

$regParams = @{
    TaskName    = $TaskName
    TaskPath    = $TaskPath
    Action      = $action
    Trigger     = $trigger
    Settings    = $settings
    Principal   = $principal
    Description = $taskDesc
}

if ($RunAsAccount -ne 'SYSTEM' -and $RunAsPassword -ne '') {
    $regParams['Password'] = $RunAsPassword
}

Register-ScheduledTask @regParams | Out-Null
Write-Host "Registered task: $TaskPath$TaskName" -ForegroundColor Green

# ─── Verify ───────────────────────────────────────────────────────────────────
$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($task) {
    Write-Host ""
    Write-Host "Installation complete." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor White
    Write-Host "  Script     : $ScriptPath"
    Write-Host "  Task       : $TaskPath$TaskName"
    Write-Host "  Runs as    : $RunAsAccount"
    Write-Host "  Interval   : Every 5 minutes"
    Write-Host "  Logs       : $LogDir"
    Write-Host "  Event Log  : Application > $EventSource"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host "  1. Verify the task in Task Scheduler under $TaskPath"
    Write-Host "  2. Do a manual test run: Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath'"
    Write-Host "  3. Check $LogDir for the first log entry"
    Write-Host "  4. Check Event Viewer -> Windows Logs -> Application, filter by Source = $EventSource"
} else {
    Write-Error "Task registration may have failed. Please verify in Task Scheduler manually."
    exit 1
}

