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
| `config.ps1` | All configuration — edit this before running anything |
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

Copy `config.ps1` and fill in all values. Key settings:

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

See `config.ps1` for the full list of options including SMTP notification settings.

### 2. Test with Let's Encrypt staging

Set `$AcmeServer = 'LE_STAGE'` in `config.ps1` before your first run. Staging certificates are not trusted by browsers but let you verify the full flow without hitting rate limits.

### 3. Run manually

```powershell
.\Invoke-CertRenewal.ps1
```

Switch to `LE_PROD` once staging succeeds, then run again with `-Force` to issue a real certificate:

```powershell
.\Invoke-CertRenewal.ps1 -Force
```

### 4. Set up automatic renewal

```powershell
.\Register-ScheduledTask.ps1
```

See [docs/scheduled-task.md](docs/scheduled-task.md) for details, including the required first-run step when using the SYSTEM account.

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

Configure the `EMAIL NOTIFICATIONS` section in `config.ps1`. An email is sent on both success and failure. Failure emails include the error message. Leave `$SmtpUsername` and `$SmtpPassword` as empty strings if your SMTP server does not require authentication.

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

**Scheduled task finds no ACME account** — the ACME account is registered under the Windows user profile of whoever ran the first issuance. If the task runs as SYSTEM, the first run must also be done as SYSTEM. See [docs/scheduled-task.md](docs/scheduled-task.md).

**Rate limited by Let's Encrypt** — use `$AcmeServer = 'LE_STAGE'` while testing. Production rate limits allow 5 duplicate certificates per week per domain.
