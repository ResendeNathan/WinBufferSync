# WinBufferSync

A lightweight, production-ready Windows Server solution for automated folder buffer synchronisation. Built with PowerShell and Robocopy — no third-party tools, no licensing, no noise.

---

## What it does

WinBufferSync moves files from one or more **source (buffer) folders** to their respective **destination folders** on a scheduled interval. It was designed to be used in environments where files are staged in a buffer folder before being consumed from a live destination or simple where you need to move files from a source to a destination.

Key behaviours:

- **Moves files** — source files are deleted after a confirmed successful copy (`/MOV`), keeping buffer folders self-cleaning
- **Handles locked files gracefully** — if a destination file is open by another process, the file is silently skipped and retried on the next cycle. No alerts, no noise
- **Structured logging** — every run is recorded in a daily rotating log file and mirrored to the Windows Event Log for monitoring integration
- **Self-maintaining** — log files older than 30 days are automatically pruned on every run

---

## Why not just use Robocopy directly?

You could. WinBufferSync adds the layer that makes Robocopy production-ready:

- **Lock detection** — distinguishes between a locked file (transient, retry silently) and a genuine error (log as ERROR, raise Event ID 1030). Robocopy treats both the same way.
- **Pre-run file count** — logs how many files were in each source before the run, making "no changes" entries meaningful rather than ambiguous
- **Post-run residual check** — detects files that remain in the source after Robocopy ran with no lock explanation, flagging them for investigation
- **Windows Event Log integration** — structured Event IDs ready for SIEM or monitoring tool consumption with zero additional configuration
- **Installer script** — one command registers the scheduled task, creates directories, and registers the Event Log source

---

## Architecture

```
Buffer folder (source)
        │
        │  every N minutes
        │  (Windows Task Scheduler)
        ▼
 WinBufferSync.ps1
        │
        ├── Robocopy /MOV ──────────────────────► Destination folder
        │
        ├── Lock detection (ERROR 32 / ERROR 5)
        │         └── [WARN] locked, retry next cycle
        │
        └── Logging
              ├── C:\Logs\WinBufferSync\WinBufferSync_yyyy-MM-dd.log
              └── Windows Event Log (Application > WinBufferSync)
```

It is highly recommended to run the scheduled task under a **Group Managed Service Account (gMSA)** — a non-interactive service identity whose password is managed automatically by Active Directory. It is completely unaffected by interactive session timeout policies.

---

## Requirements

| Component | Minimum version |
|---|---|
| Windows Server | 2016 or later (tested on 2025) |
| PowerShell | 5.1 or later |
| Robocopy | Built into Windows — no installation needed |
| Active Directory | Required for gMSA (recommended) |

> **Service account:** A Group Managed Service Account is strongly recommended over a standard user account or SYSTEM. gMSA passwords are managed automatically by AD with no manual rotation required. See [Microsoft's gMSA documentation](https://learn.microsoft.com/en-us/windows-server/security/group-managed-service-accounts/group-managed-service-accounts-overview) for setup guidance. A standard service account with "Log on as a batch job" rights works as an alternative.

---

## Files

```
WinBufferSync/
├── WinBufferSync.ps1         # Sync engine — edit $SyncPairs here
└── Register-WinBufferSync.ps1   # One-time installer
```

---

## Quick Start

**1. Clone or download the repository**

Place both scripts in the same folder on the target server (e.g. `C:\Scripts\WinBufferSync\`).

**2. Configure your sync pairs**

Open `WinBufferSync.ps1` and edit the `$SyncPairs` array at the top of the file:

```powershell
$SyncPairs = @(
    [PSCustomObject]@{
        Name        = 'Directory NAME' # for logging purposes - Use a name that makes it easy to identify this pair.
        Source      = 'D:\Example\Source\Path' # the folder where the files are initially stroed.
        Destination = 'D:\Example\Destination\Path' # the folder where the files should be moved to.
    },
    [PSCustomObject]@{
        Name        = 'Directory NAME 02' # for logging purposes - Use a name that makes it easy to identify this pair.
        Source      = 'D:\Example\Source\Path02' # the folder where the files are initially stroed.
        Destination = 'D:\Example\Destination\Path02' # the folder where the files should be moved to.
    }
)
```

Add as many pairs as needed. Each pair runs as a separate Robocopy job within the same scheduled execution.

**3. Run the installer** (as Administrator)

```powershell
# With a Group Managed Service Account (Highly recommended)
.\Register-WinBufferSync.ps1 -RunAsAccount 'DOMAIN\svcWinBufferSync$'

# With a standard service account
.\Register-WinBufferSync.ps1 -RunAsAccount 'DOMAIN\svc-wbsync' -RunAsPassword 'YourPassword'

# With SYSTEM (quick test — not recommended for production)
.\Register-WinBufferSync.ps1
```

The installer will:
- Create `C:\Scripts\WinBufferSync\` and `C:\Logs\EPDMSync\` if doesn't exists
- Register the `WinBufferSync` source in the Windows Application Event Log
- Create the scheduled task under `\WinBufferSync\Sync Task`

**4. Verify**

```powershell
# Check the task is registered and in Ready state
Get-ScheduledTask -TaskName 'WinBufferSync' -TaskPath '\IT Infrastructure\' |
    Select-Object TaskName, State, @{N='LastRun';E={$_.LastRunTime}}

# Trigger a manual run
Start-ScheduledTask -TaskName 'WinBufferSync' -TaskPath '\IT Infrastructure\'
Start-Sleep 15

# Check the log
Get-Content "C:\Logs\WinBufferSync\WinBufferSync_$(Get-Date -Format 'yyyy-MM-dd').log" -Tail 20
```

---

## Configuration Reference

All configuration lives at the top of `WinBufferSync.ps1`. No other file needs to be edited for day-to-day changes.

| Variable | Default | Description |
|---|---|---|
| `$SyncPairs` | *(see script)* | Array of source/destination pairs. Add, remove, or edit entries freely. Changes take effect on the next scheduled run — no task re-registration needed. |
| `$LogDir` | `C:\Logs\WinBufferSync` | Directory for daily log files and per-pair Robocopy logs. |
| `$LogFile` | `EWinBufferSync_yyyy-MM-dd.log` | Daily rotating log. One file per calendar day. |
| `$EventSource` | `WinBufferSync` | Windows Event Log source name. |
| `$EventLog` | `Application` | Windows Event Log target. |

### Robocopy flags used

| Flag | Purpose |
|---|---|
| `/MOV` | Move files — delete from source after confirmed copy |
| `/E` | Include all subdirectories including empty ones |
| `/DCOPY:T` | Preserve directory timestamps |
| `/COPY:DT` | Copy data and timestamps only — ACLs are excluded intentionally |
| `/R:0` | Zero retries per file — the scheduler cycle is the retry mechanism |
| `/W:0` | Zero wait between retries |
| `/NP` | No progress percentage output |
| `/NDL` | No directory listing output |
| `/LOG:` | Write raw output to a per-pair log file for debugging |

---

## Logging

### Daily log file

One file per day at `C:\Logs\WinBufferSync\WinBufferSync_yyyy-MM-dd.log`. Files older than 30 days are deleted automatically.

```
[2026-05-27 08:06:47] [INFO] === Sync run started ===
[2026-05-27 08:06:47] [INFO] [PDF] Starting | Source files before run: 3 | D:\Buffer\PDF -> D:\Live\PDF
[2026-05-27 08:06:51] [INFO] [PDF] Result | copied: 3 | locked/retrying: 0 | errors: 0
[2026-05-27 08:06:51] [INFO] [Reports] Starting | Source files before run: 0 | ...
[2026-05-27 08:06:55] [INFO] [Reports] No changes - source is empty or destination already up to date
[2026-05-27 08:06:55] [INFO] === Run complete in 8.6s | copied: 3 | locked/retrying: 0 | errors: 0 ===
```

When a file is locked:
```
[2026-05-27 08:10:25] [WARN] [PDF] Locked, will retry next cycle: quarterly-report.pdf
```

### Windows Event Log

All runs are mirrored to `Windows Logs > Application`, Source: `WinBufferSync`.

| Event ID | Level | Meaning |
|---|---|---|
| 1001 | Information | Sync run started |
| 1002 | Information | Run completed successfully |
| 1010 | Warning | Source folder not found |
| 1020 | Warning | File locked — will retry next cycle |
| 1030 | Error | Permanent Robocopy failure — investigate |
| 1099 | Error | Run completed with one or more permanent errors |

```powershell
# Query from PowerShell
Get-EventLog -LogName Application -Source WinBufferSync -Newest 20 |
    Format-Table TimeGenerated, EntryType, EventID, Message -Wrap
```

---

## NTFS Permissions

Grant the service account the minimum permissions required:

```powershell
# Read on all source (buffer) folders
icacls "D:\Example\Source\Path"     /grant "DOMAIN\svcWinBufferSync$:(OI)(CI)M" /T

# Modify on all destination folders
icacls "D:\Example\Destination\Path"       /grant "DOMAIN\svcWinBufferSync$:(OI)(CI)M" /T

```

## Uninstalling

```powershell
.\Register-WinBufferSync.ps1 -Uninstall
```

This removes the scheduled task and deregisters the Event Log source. Script files and log files are **not** deleted — remove them manually if no longer needed.

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Log shows "no changes" but files exist in source | NTFS permission missing on source | Verify `icacls` on source folder for the service account |
| Task state is Disabled | Manual disable or GPO | `Enable-ScheduledTask -TaskName 'WinBufferSync' -TaskPath '\IT Infrastructure\'` |
| Event ID 1030 in Event Log | Permanent Robocopy error | Open `C:\Logs\WinBufferSync\Robocopy_PAIRNAME.log` immediately — overwritten every 5 min |
| File stuck in buffer across many cycles | File held open continuously | `openfiles /query /fo TABLE \| findstr /i "filename.ext"` |

---

## License

MIT — free to use, modify, and distribute.

---

## Colaboration

All suggestion and colaboration are more then welcome, so, feel free to colaborate with me on this!

---

## Author

Nathan Resende da Silva Pinto - 🌐 https://www.linkedin.com/in/nathan-resende/
