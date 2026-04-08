# Scheduled Task Setup

This document explains how to set up automated certificate renewal as a Windows scheduled task.

---

## Prerequisites

- PowerShell 5.1
- Run all setup steps as **Administrator**
- `config.ps1` fully configured (see the root of the repo)
- posh-acme installed: `Install-Module Posh-ACME -Scope AllUsers`
- The ACME account must be registered **before** the scheduled task runs for the first time (see below)

---

## Option A — Automated Setup (Recommended)

Run the registration script. It creates and configures the task in one step.

```powershell
# Default: runs daily at 3 AM as SYSTEM
.\Register-ScheduledTask.ps1

# Custom time and task name
.\Register-ScheduledTask.ps1 -TriggerHour 2 -TaskName 'LetsEncrypt-Renewal'

# Run as a specific service account instead of SYSTEM
.\Register-ScheduledTask.ps1 -RunAsUser 'DOMAIN\svc-certrenew'
```

---

## Option B — Manual Setup via Task Scheduler GUI

1. Open **Task Scheduler** (`taskschd.msc`)
2. Click **Create Task** (not "Create Basic Task")
3. **General** tab:
   - Name: `ACME-CertRenewal`
   - Security options: **Run whether user is logged on or not**
   - Check **Run with highest privileges**
   - Configure for: **Windows 10** (or your OS version)
4. **Triggers** tab → New:
   - Begin the task: **On a schedule**
   - Daily, at **3:00 AM**
   - Check **Enabled**
5. **Actions** tab → New:
   - Action: **Start a program**
   - Program: `powershell.exe`
   - Arguments:
     ```
     -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Invoke-CertRenewal.ps1"
     ```
6. **Conditions** tab:
   - Check **Start only if the following network connection is available**: Any connection
7. **Settings** tab:
   - Check **Run task as soon as possible after a scheduled start is missed**
   - Set **Stop the task if it runs longer than**: 1 hour
   - If the task is already running: **Do not start a new instance**
8. Click **OK** and enter the account password when prompted

---

## First Run — ACME Account Registration

posh-acme stores ACME account state on disk under the profile of the account running it.
When the scheduled task runs as **SYSTEM**, the state lives at:

```
C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME
```

**You must perform the first run as SYSTEM** so the account is registered under the correct profile.
Do this before relying on the scheduled task:

```powershell
# Launch a SYSTEM shell using PsExec (from Sysinternals)
psexec -s -i powershell.exe

# Inside that shell:
cd C:\path\to\pdns-acme-cert
.\Invoke-CertRenewal.ps1
```

Or trigger the task immediately after registering it:

```powershell
Start-ScheduledTask -TaskName 'ACME-CertRenewal'
```

Then check the result:

```powershell
(Get-ScheduledTaskInfo -TaskName 'ACME-CertRenewal').LastTaskResult
# 0 = success
```

---

## Renewal Behavior

posh-acme automatically skips renewal if the certificate is **more than 30 days from expiry**.
Running daily is safe — most runs will be no-ops.

To force a renewal regardless of expiry:

```powershell
.\Invoke-CertRenewal.ps1 -Force
```

---

## Viewing Task Output

Scheduled task output is not captured by default. To log output, redirect in the task action:

```
-NonInteractive -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\path\to\Invoke-CertRenewal.ps1' *>> 'C:\Logs\cert-renewal.log'"
```

Or view the Windows Event Log:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' |
    Where-Object { $_.Message -like '*ACME-CertRenewal*' } |
    Select-Object -First 20
```

---

## Removing the Task

```powershell
Unregister-ScheduledTask -TaskName 'ACME-CertRenewal' -Confirm:$false
```
