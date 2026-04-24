# Scheduled Task Setup

Automated renewal is the intended production mode. `Invoke-CertRenewal.ps1` is a no-op when
the certificate has more than 30 days remaining, so running it daily is safe. When the 30-day
window is hit, it issues a new certificate and installs it automatically.

The setup order matters: **register the task first, then do the first run as SYSTEM**. Running
interactively as yourself registers the ACME account under your profile — not SYSTEM's — and the
scheduled task will fail looking for an account that does not exist.

---

## Prerequisites

- PowerShell 5.1
- Run all setup steps as **Administrator**
- `config.ps1` present and configured — copy `config.example.ps1` to `config.ps1` and fill in your values
- posh-acme installed: `Install-Module Posh-ACME -Scope AllUsers`

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

posh-acme stores ACME account state (ACME key pair, server URL, cached cert) on disk under
the profile of the account that ran it. When the scheduled task runs as **SYSTEM**, that state
lives at:

```
C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME
```

If you ran `Invoke-CertRenewal.ps1` interactively as yourself first, that registered the ACME
account under **your** profile — not SYSTEM's. The scheduled task will fail trying to look up an
account that does not exist in the SYSTEM profile.

**Always do the first run as SYSTEM**, before relying on the scheduled task.

---

### Get PsExec

PsExec is part of the free [Sysinternals Suite](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec).

```powershell
# Download PsExec directly (run as Administrator):
Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/PSTools.zip' -OutFile "$env:TEMP\PSTools.zip"
Expand-Archive -Path "$env:TEMP\PSTools.zip" -DestinationPath "$env:TEMP\PSTools"
Copy-Item "$env:TEMP\PSTools\PsExec64.exe" -Destination 'C:\Windows\System32\PsExec64.exe'
```

Or download manually from: `https://learn.microsoft.com/en-us/sysinternals/downloads/psexec`

---

### Run the first issuance as SYSTEM

Open an **elevated** PowerShell prompt (Run as Administrator), then:

```powershell
# Open an interactive SYSTEM shell
PsExec64.exe -s -i powershell.exe
```

Accept the PsExec EULA if prompted (first run only). A new PowerShell window opens running as SYSTEM.

Verify the identity in that window:

```powershell
[System.Security.Principal.WindowsIdentity]::GetCurrent().Name
# Should output: NT AUTHORITY\SYSTEM
```

Then run the renewal script:

```powershell
Set-Location 'C:\path\to\pdns-acme-cert'
.\Invoke-CertRenewal.ps1
```

On first run this will:
1. Install posh-acme (if not already installed AllUsers scope)
2. Register a new ACME account with Let's Encrypt
3. Issue the certificate via DNS-01 challenge
4. Install the certificate (IIS or LDAP depending on `$CertTarget`)
5. Send an email notification if configured

Subsequent scheduled task runs reuse the registered account and only renew when the
certificate is within 30 days of expiry.

---

### Verify success

After the SYSTEM shell run completes without errors, confirm the account state exists:

```powershell
Test-Path 'C:\Windows\System32\config\systemprofile\AppData\Local\Posh-ACME'
# Should be True
```

Then trigger the scheduled task once to confirm it works end-to-end:

```powershell
Start-ScheduledTask -TaskName 'ACME-CertRenewal'
Start-Sleep -Seconds 10
(Get-ScheduledTaskInfo -TaskName 'ACME-CertRenewal').LastTaskResult
# 0 = success; anything else = failure (see Troubleshooting below)
```

---

### Troubleshooting exit code 1

If the task exits with code 1, enable logging to capture the error:

**Option 1 — Log file** (edit the task action arguments):
```
-NonInteractive -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\path\to\Invoke-CertRenewal.ps1' *>> 'C:\Logs\cert-renewal.log'"
```

**Option 2 — Re-run interactively as SYSTEM** with PsExec to see live output:
```powershell
PsExec64.exe -s -i powershell.exe
# In the SYSTEM shell:
Set-Location 'C:\path\to\pdns-acme-cert'
.\Invoke-CertRenewal.ps1
```

Common causes:
| Symptom | Cause | Fix |
|---|---|---|
| `No ACME account found` | First run not done as SYSTEM | Run PsExec steps above |
| `Configuration file not found` | `config.ps1` missing | Copy `config.example.ps1` to `config.ps1` and fill in values |
| `PfxPassword` variable not found | `$PfxPassword` missing from `config.ps1` | Add `$PfxPassword = 'poshacme'` (or your chosen value) |
| TLS / SSL errors | PowerDNS self-signed cert | Set `$PdnsSkipSslVerify = $true` in `config.ps1` |
| DNS NXDOMAIN during validation | TXT record not yet visible on all NS | Increase `$PdnsPropagationTimeout` (300 recommended) |
| `WebAdministration module not found` | IIS management tools not installed | `Install-WindowsFeature -Name Web-Mgmt-Tools` |

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
