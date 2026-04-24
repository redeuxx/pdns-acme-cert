# Scheduled Task Setup

Automated renewal is the intended production mode. `Invoke-CertRenewal.ps1` is a no-op when
the certificate has more than 30 days remaining, so running it daily is safe. When the 30-day
window is hit, it issues a new certificate and installs it automatically.

The setup order matters: **register the task before running the script interactively as yourself**.
If you run `Invoke-CertRenewal.ps1` as your own user first, posh-acme registers the ACME account
under your profile. The scheduled task runs as SYSTEM and has its own profile, so it will not find
that account. Let the scheduled task do the first run.

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

## First Run — Verify with a Manual Trigger

The scheduled task handles everything automatically, including ACME account registration on first
run. You do not need to run the script manually or use PsExec.

To verify the setup before waiting for the daily schedule, trigger the task manually:

```powershell
Start-ScheduledTask -TaskName 'ACME-CertRenewal'
```

On first run the task will:
1. Install posh-acme if missing (AllUsers scope)
2. Register a new ACME account with Let's Encrypt
3. Issue the certificate via DNS-01 challenge
4. Install the certificate (IIS or LDAP depending on `$CertTarget`)
5. Send an email notification if configured

Subsequent runs reuse the registered account and only renew when the certificate is within
30 days of expiry.

Use `$AcmeServer = 'LE_STAGE'` in `config.ps1` for your first test run to avoid hitting
production rate limits. Once staging succeeds, switch to `LE_PROD`.

---

### Check the result

```powershell
Start-Sleep -Seconds 10
(Get-ScheduledTaskInfo -TaskName 'ACME-CertRenewal').LastTaskResult
# 0 = success; anything else = failure (see Troubleshooting below)
```

---

### Troubleshooting exit code 1

Enable logging to capture the error output:

```
-NonInteractive -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\path\to\Invoke-CertRenewal.ps1' *>> 'C:\Logs\cert-renewal.log'"
```

Common causes:
| Symptom | Cause | Fix |
|---|---|---|
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
