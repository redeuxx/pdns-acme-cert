# ACME CERTIFICATE AUTOMATION - CONFIGURATION
# Copy this file to config.ps1 and fill in your values.
# config.ps1 is gitignored so your credentials stay local.

# ACME ACCOUNT
$ContactEmail   = 'admin@example.com'
$AcmeServer     = 'LE_PROD'     # LE_PROD or LE_STAGE (use LE_STAGE for testing)

# CERTIFICATE DOMAINS
# For a single domain:      $Domains = @('example.com')
# For a wildcard:           $Domains = @('*.example.com')
# For both (SAN cert):      $Domains = @('example.com', '*.example.com')
$Domains        = @('example.com')

# POWERDNS API
$PdnsBaseUrl    = 'https://pdns.example.com:8081'
$PdnsApiKey     = 'your-api-key-here'
$PdnsServerId   = 'localhost'
$PdnsSkipSslVerify       = $false   # Set $true if PowerDNS uses a self-signed certificate
# Seconds to actively poll all authoritative nameservers for the zone after creating the TXT
# record, confirming visibility before Let's Encrypt validates. Set to 0 to disable.
# Recommended when using LE_PROD (multi-perspective validation requires all NS servers to agree).
$PdnsPropagationTimeout  = 300
# DNS servers to poll during propagation check. Leave empty (@()) to auto-discover from NS records.
# Specify explicit servers if NS lookup fails, or to check resolvers rather than authoritative NS.
# Example: $PdnsPropagationServers = @('8.8.8.8', '1.1.1.1', 'ns1.example.com')
$PdnsPropagationServers  = @()

# DNS PROPAGATION WAIT
# Additional fixed sleep (seconds) after the propagation check completes.
# Can usually be left at 30 when PdnsPropagationTimeout is enabled.
$DnsPropagationDelay = 30

# LOCAL PFX PASSWORD
# Password applied to the PFX file stored on disk by posh-acme. This protects the file
# container format only - the real security is filesystem permissions. Must be non-empty
# (Windows DPAPI is used instead when blank, which breaks import under a different account).
$PfxPassword    = 'poshacme'

# CERTIFICATE TARGET
# What to install the certificate into.
# Valid values: 'IIS', 'LDAP'
$CertTarget     = 'IIS'

# IIS SETTINGS (used when $CertTarget = 'IIS')
$IISSiteName    = 'Default Web Site'
$IISBindingPort = '443'
$IISHostHeader  = ''            # Leave empty to match all host headers on the port

# LDAP SETTINGS (used when $CertTarget = 'LDAP')
# Valid values: 'ADLDAPS' (Active Directory) or 'Standalone' (other LDAP server)
$LdapType       = 'ADLDAPS'
# Service name for standalone LDAP (ignored for ADLDAPS)
$LdapServiceName = 'slapd'

# EMAIL NOTIFICATIONS
$SmtpServer        = 'smtp.example.com'
$SmtpPort          = 25
$SmtpUseSsl        = $false
$SmtpSkipSslVerify = $false    # Set $true if SMTP server uses a self-signed certificate
$SmtpUsername      = ''        # Leave empty for open relay (no authentication)
$SmtpPassword      = ''        # Leave empty for open relay (no authentication)
$EmailFrom         = 'certbot@example.com'
$EmailTo           = @('admin@example.com')    # One or more recipients

# RESTART BEHAVIOR
# For ADLDAPS: 'Service' restarts only the NTDS/Kerberos services; 'Reboot' reboots the DC.
# Service restart is sufficient in most cases. Use Reboot only if Service does not apply the cert.
$ADRestartMode  = 'Service'     # 'Service' or 'Reboot'
