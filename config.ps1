# ACME CERTIFICATE AUTOMATION - CONFIGURATION
# Dot-source this file in other scripts:  . "$PSScriptRoot\config.ps1"

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
$PdnsSkipSslVerify = $false     # Set $true if PowerDNS uses a self-signed certificate

# DNS PROPAGATION WAIT
# Seconds to wait after creating the DNS TXT record before requesting validation.
# Increase if your DNS TTL is high or propagation is slow.
$DnsPropagationDelay = 30

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
