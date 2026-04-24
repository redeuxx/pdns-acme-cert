# pdns-acme-cert

Automated Let's Encrypt certificate issuance and installation for Windows, using [posh-acme](https://github.com/rmbolger/Posh-ACME) with DNS-01 validation via the PowerDNS API.

Supports installing certificates into **IIS** or **Active Directory LDAPS**.

---

## Requirements

- Windows, PowerShell 5.1
- Run as **Administrator**
- [posh-acme](https://github.com/rmbolger/Posh-ACME) — installed automatically on first run if missing
- PowerDNS with the HTTP API enabled
- For IIS installs: IIS Management Tools (`WebAdministration` module) — see [below](#webadministration-module)

---

## Files

| File | Purpose |
|---|---|
| `config.example.ps1` | Configuration template — copy to `config.ps1` and fill in your values |
| `Invoke-CertRenewal.ps1` | Main entry point — issues and installs the certificate |
| `New-AcmeCert.ps1` | posh-acme issuance logic |
| `Install-CertIIS.ps1` | Binds the certificate to an IIS site |
| `Install-CertLDAP.ps1` | Installs the certificate for AD LDAPS or a standalone LDAP server |
| `Send-Notification.ps1` | Sends success/failure email notifications |
| `Register-ScheduledTask.ps1` | Registers a Windows scheduled task for automatic renewal |
| `Plugins/PowerDNS.ps1` | Custom posh-acme DNS plugin for PowerDNS |
| `docs/scheduled-task.md` | Scheduled task setup and first-run instructions |

---

## Setup

### 1. Configure

Copy `config.example.ps1` to `config.ps1` and fill in your values. `config.ps1` is gitignored so your credentials stay local.

```powershell
Copy-Item config.example.ps1 config.ps1
```

Key settings:

```powershell
# Your domain(s) — single, wildcard, or both as a SAN cert
$Domains        = @('example.com', '*.example.com')

# Let's Encrypt account email
$ContactEmail   = 'admin@example.com'

# Use LE_STAGE for testing, LE_PROD when ready
$AcmeServer     = 'LE_STAGE'

# PowerDNS API
$PdnsBaseUrl    = 'https://pdns.example.com:8081'
$PdnsApiKey     = 'your-api-key-here'

# What to install the certificate into: 'IIS' or 'LDAP'
$CertTarget     = 'IIS'
```

See `config.example.ps1` for the full list of options including SMTP notification settings.

### 2. Register the scheduled task

```powershell
.\Register-ScheduledTask.ps1
```

This creates a daily renewal task that runs as **SYSTEM**. See [docs/scheduled-task.md](docs/scheduled-task.md) for custom options (run time, task name, service account).

### 3. First run as SYSTEM

posh-acme stores ACME account state in the profile of the account that runs it. Because the scheduled task runs as SYSTEM, **the first run must also be done as SYSTEM** to register the account in the right profile.

Use PsExec (from [Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec)) to open a SYSTEM shell:

```powershell
PsExec64.exe -s -i powershell.exe
```

Then inside that shell:

```powershell
Set-Location 'C:\path\to\pdns-acme-cert'
.\Invoke-CertRenewal.ps1
```

Use `$AcmeServer = 'LE_STAGE'` for this first run to verify the full flow without hitting production rate limits. Once staging succeeds, switch to `LE_PROD` and run again with `-Force`:

```powershell
.\Invoke-CertRenewal.ps1 -Force
```

See [docs/scheduled-task.md](docs/scheduled-task.md) for the complete walkthrough, including PsExec setup and troubleshooting exit code 1.

---

## How renewal works

posh-acme tracks the existing certificate's expiry. Each run of `Invoke-CertRenewal.ps1` is a no-op if the certificate has more than 30 days remaining. When the 30-day window is hit, it issues a new certificate and installs it automatically.

Running the scheduled task daily is safe — nearly every run does nothing.

---

## Certificate targets

### IIS

The script binds the new certificate to the configured site and port, replacing the existing binding. No IIS restart is required.

### AD LDAPS

The Domain Controller auto-selects a certificate from `Cert:\LocalMachine\My` at NTDS startup. The script imports the new certificate, removes old certificates with overlapping domain names to prevent ambiguity, then restarts the NTDS and KDC services. Set `$ADRestartMode = 'Reboot'` in `config.ps1` if a full DC reboot is required in your environment.

---

## Email notifications

Configure the `EMAIL NOTIFICATIONS` section in `config.ps1`. An email is sent on both success and failure. Failure emails include the error message.

**Open relay** (no authentication): leave `$SmtpUsername` and `$SmtpPassword` as empty strings and set `$SmtpUseSsl = $false`.

**Authenticated relay**: set `$SmtpUsername`, `$SmtpPassword`, and `$SmtpPort` to match your server. Set `$SmtpUseSsl = $true` if the server requires it.

**Self-signed SMTP certificate**: set `$SmtpSkipSslVerify = $true` to bypass certificate validation (useful on internal mail servers).

---

## WebAdministration module

The `WebAdministration` module is required for IIS installs. It ships with Windows and is not available on PSGallery — it must be enabled as a Windows Feature.

**Check if already installed:**

```powershell
Get-Module -ListAvailable -Name WebAdministration
```

No output means it is not installed.

**Install on Windows Server:**

```powershell
Install-WindowsFeature -Name Web-Mgmt-Tools
```

**Install on Windows 10/11:**

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName IIS-ManagementConsole
```

Both commands require Administrator. A reboot may be required. Verify the install worked:

```powershell
Import-Module WebAdministration
Get-WebSite
```

If `Get-WebSite` lists your sites without error, the module is ready.

---

## Troubleshooting

**DNS challenge fails** — increase `$DnsPropagationDelay` in `config.ps1`. The default is 30 seconds; try 60–120 if your DNS TTL is high.

**PowerDNS API SSL errors** — set `$PdnsSkipSslVerify = $true` if the PowerDNS API uses a self-signed certificate.

**SMTP SSL errors** — set `$SmtpSkipSslVerify = $true` if the SMTP server uses a self-signed certificate.

**Scheduled task finds no ACME account** — the ACME account is registered under the Windows user profile of whoever ran the first issuance. If the task runs as SYSTEM, the first run must also be done as SYSTEM. See [docs/scheduled-task.md](docs/scheduled-task.md).

**Rate limited by Let's Encrypt** — use `$AcmeServer = 'LE_STAGE'` while testing. Production rate limits allow 5 duplicate certificates per week per domain.

**posh-acme fails to install on Windows Server 2019** — `Install-Module` may fail with SSL/TLS errors if the server's cipher suite list is missing `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384` / `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`, which PSGallery requires. Apply the Best Practices template using [IIS Crypto CLI](https://www.nartac.com/Products/IISCrypto) and reboot:

```powershell
.\IISCryptoCli.exe /template best
```
