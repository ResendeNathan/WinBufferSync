#Requires -Version 5.1

$SyncPairs = @(
    [PSCustomObject]@{
        Name        = 'Directory NAME' # for logging purposes - Use a name that makes it easy to identify this pair.
        Source      = 'D:\Example\Source\Path' # the folder where the files are initially stroed.
        Destination = 'D:\Example\Destination\Path' # the folder where the files should be moved to.
    },
    [PSCustomObject]@{
        Name        = 'Directory NAME'
        Source      = 'D:\Example\Source\Path'
        Destination = 'D:\Example\Destination\Path'
    },
    [PSCustomObject]@{
        Name        = 'Directory NAME'
        Source      = 'D:\Example\Source\Path'
        Destination = 'D:\Example\Destination\Path'
    }
)

$LogDir      = 'C:\Logs\WinBufferSync' #The folder where sync logs will be stored.
$LogFile     = Join-Path $LogDir ("WinBufferSync_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$EventSource = 'WinBufferSync'
$EventLog    = 'Application'

function Initialize-Logging {
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        try { New-EventLog -LogName $EventLog -Source $EventSource -ErrorAction Stop }
        catch { }
    }
    Get-ChildItem -Path $LogDir -Filter 'WinBufferSync_*.log' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-SyncLog {
    param(
        [string] $Message,
        [ValidateSet('INFO','WARN','ERROR')] [string] $Level = 'INFO',
        [int] $EventId = 1000
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line      = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    $entryType = switch ($Level) {
        'WARN'  { 'Warning' }
        'ERROR' { 'Error' }
        default { 'Information' }
    }
    try {
        Write-EventLog -LogName $EventLog -Source $EventSource `
            -EntryType $entryType -EventId $EventId -Message $Message `
            -ErrorAction SilentlyContinue
    } catch { }
    Write-Host $line
}

function Invoke-RobocopyPair {
    param([PSCustomObject] $Pair)

    $result = [PSCustomObject]@{
        Name        = $Pair.Name
        FilesInSource = 0
        Copied      = 0
        Locked      = 0
        Failed      = 0
        ErrorDetail = [System.Collections.Generic.List[string]]::new()
        Success     = $true
    }

    # Validate source
    if (-not (Test-Path -LiteralPath $Pair.Source -PathType Container)) {
        $msg = "[$($Pair.Name)] Source folder not found: $($Pair.Source)"
        Write-SyncLog -Message $msg -Level 'WARN' -EventId 1010
        $result.Success = $false
        $result.ErrorDetail.Add($msg)
        return $result
    }

    # Count files in source BEFORE running robocopy - this is our ground truth
    $sourceFiles = Get-ChildItem -LiteralPath $Pair.Source -Recurse -File -ErrorAction SilentlyContinue
    $result.FilesInSource = $sourceFiles.Count

    # Ensure destination exists
    if (-not (Test-Path -LiteralPath $Pair.Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Pair.Destination -Force | Out-Null
        Write-SyncLog -Message "[$($Pair.Name)] Created destination folder: $($Pair.Destination)"
    }

    # Per-pair robocopy log - overwritten each run, we parse it immediately after
    $robocopyLog = Join-Path $LogDir ("Robocopy_$($Pair.Name).log")

    # /MOV  = move files (delete from source after successful copy)
    # /E    = include subdirectories including empty ones
    # /R:0  = no retries per file (scheduler is the retry mechanism)
    # /W:0  = no wait between retries
    # /NP   = no progress output
    # /NDL  = no directory listing
    # /DCOPY:T = preserve directory timestamps
    # /COPY:DT = copy data + timestamps only (not ACLs)
    $robocopyArgs = @(
        "`"$($Pair.Source)`"",
        "`"$($Pair.Destination)`"",
        '/MOV', '/E', '/DCOPY:T', '/COPY:DT',
        '/R:0', '/W:0', '/NP', '/NDL',
        "/LOG:`"$robocopyLog`""
    )

    $proc = Start-Process -FilePath 'robocopy.exe' `
                          -ArgumentList $robocopyArgs `
                          -NoNewWindow -Wait -PassThru

    $exitCode = $proc.ExitCode

    # Parse the robocopy log file - this is always written regardless of stdout behaviour
    $logContent = @()
    if (Test-Path $robocopyLog) {
        $logContent = Get-Content $robocopyLog -ErrorAction SilentlyContinue
    }

    # Extract the Files summary line: "Files :      5      3      0      0      2      0"
    # Columns:                          Total  Copied  Skipped  Mismatch  Failed  Extras
    $summaryLine = $logContent | Where-Object { $_ -match '^\s+Files\s*:' } | Select-Object -Last 1
    if ($summaryLine -match 'Files\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
        $result.Copied = [int]$Matches[2]
        $result.Failed = [int]$Matches[5]
    }

    # Detect locked files - ERROR 32 = sharing violation, ERROR 5 = access denied by lock
    $lockedLines = $logContent | Where-Object { $_ -match 'ERROR\s+(32|5)\s+\(' }
    foreach ($line in $lockedLines) {
        $result.Locked++
        $result.Failed = [Math]::Max(0, $result.Failed - 1)
        if ($line -match '\\([^\\]+\.[^\\]+)\s*$') {
            $result.ErrorDetail.Add("Locked, will retry next cycle: $($Matches[1])")
        }
    }

    # Also check for any other error lines in the log
    $otherErrors = $logContent | Where-Object { $_ -match 'ERROR\s+\d+' -and $_ -notmatch 'ERROR\s+(32|5)\s+\(' }
    foreach ($line in $otherErrors) {
        $result.ErrorDetail.Add("Error: $($line.Trim())")
    }

    # Count what's left in source after robocopy ran - locked files stay behind
    $remainingFiles = (Get-ChildItem -LiteralPath $Pair.Source -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($result.Locked -eq 0 -and $remainingFiles -gt 0 -and $result.Copied -eq 0) {
        # Files present but not copied and no detected lock - flag for investigation
        $result.ErrorDetail.Add("$remainingFiles file(s) remain in source but were not moved - check Robocopy_$($Pair.Name).log")
    }

    # Exit codes 0-3 are all healthy for robocopy
    if ($exitCode -ge 8 -and $result.Failed -gt 0) {
        $result.Success = $false
    }

    return $result
}

# --- MAIN ---
Initialize-Logging

$runStart = Get-Date
Write-SyncLog -Message "=== Sync run started ===" -EventId 1001

$totalCopied  = 0
$totalLocked  = 0
$totalFailed  = 0

foreach ($pair in $SyncPairs) {
    Write-SyncLog -Message "[$($pair.Name)] Starting | Source files before run: $(( Get-ChildItem -LiteralPath $pair.Source -Recurse -File -ErrorAction SilentlyContinue).Count) | $($pair.Source) -> $($pair.Destination)"

    $r = Invoke-RobocopyPair -Pair $pair

    $totalCopied += $r.Copied
    $totalLocked += $r.Locked
    $totalFailed += $r.Failed

    if ($r.Copied -gt 0 -or $r.Locked -gt 0 -or $r.Failed -gt 0) {
        Write-SyncLog -Message "[$($r.Name)] Result | copied: $($r.Copied) | locked/retrying: $($r.Locked) | errors: $($r.Failed)"
    } else {
        Write-SyncLog -Message "[$($r.Name)] No changes - source is empty or destination already up to date"
    }

    foreach ($detail in $r.ErrorDetail) {
        $level = if ($detail -match 'Locked') { 'WARN' } else { 'ERROR' }
        $eventId = if ($detail -match 'Locked') { 1020 } else { 1030 }
        Write-SyncLog -Message "[$($r.Name)] $detail" -Level $level -EventId $eventId
    }
}

$duration = [Math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
$level    = if ($totalFailed -gt 0) { 'ERROR' } elseif ($totalLocked -gt 0) { 'WARN' } else { 'INFO' }
$eventId  = if ($totalFailed -gt 0) { 1099 } else { 1002 }

Write-SyncLog -Message "=== Run complete in ${duration}s | copied: $totalCopied | locked/retrying: $totalLocked | errors: $totalFailed ===" -Level $level -EventId $eventId
