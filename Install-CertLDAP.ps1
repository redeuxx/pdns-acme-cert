# LDAP CERTIFICATE INSTALLATION
# Installs a certificate for use with LDAPS.
# Supports Active Directory (ADLDAPS) and standalone LDAP servers.

#Requires -Version 5.1
#Requires -RunAsAdministrator

function Install-CertToLDAP {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PfxPath,
        [Parameter(Mandatory)][SecureString]$PfxPassword,
        [Parameter(Mandatory)]
        [ValidateSet('ADLDAPS','Standalone')]
        [string]$LdapType,

        # Used only when $LdapType = 'Standalone'
        [string]$LdapServiceName = 'slapd',

        # How to apply the cert on an AD domain controller
        [ValidateSet('Service','Reboot')]
        [string]$ADRestartMode = 'Service'
    )

    switch ($LdapType) {
        'ADLDAPS'    { Install-ADLDAPSCert    -PfxPath $PfxPath -PfxPassword $PfxPassword -RestartMode $ADRestartMode }
        'Standalone' { Install-StandaloneLDAPCert -PfxPath $PfxPath -PfxPassword $PfxPassword -ServiceName $LdapServiceName }
    }
}

# AD LDAPS

function Install-ADLDAPSCert {
    param(
        [string]$PfxPath,
        [SecureString]$PfxPassword,
        [string]$RestartMode
    )

    # AD LDAPS auto-selects a certificate from Cert:\LocalMachine\My at NTDS startup.
    # Selection criteria: Server Authentication EKU + SAN/CN matching the DC FQDN.
    # If multiple matching certs exist it picks the one with the longest remaining validity.
    # To guarantee the new cert is used, we remove old matching certs after importing.

    Write-Host 'Installing certificate for AD LDAPS...'

    # Snapshot existing certs in the store before import so we know what to clean up.
    $beforeThumbprints = (Get-ChildItem 'Cert:\LocalMachine\My').Thumbprint

    $imported = Import-PfxCertificate `
        -FilePath          $PfxPath `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -Password          $PfxPassword `
        -ErrorAction       Stop

    $newThumbprint = $imported.Thumbprint
    Write-Host "Certificate imported. Thumbprint: $newThumbprint"

    # REMOVE OLD MATCHING CERTIFICATES
    # Find certs that were present before the import and share at least one Subject name
    # with the new cert. These are candidates the DC would otherwise compete with.

    $newNames = @($imported.DnsNameList | ForEach-Object { $_.Unicode })

    foreach ($tp in $beforeThumbprints) {
        $old = Get-Item "Cert:\LocalMachine\My\$tp" -ErrorAction SilentlyContinue
        if (-not $old) { continue }

        $oldNames = @($old.DnsNameList | ForEach-Object { $_.Unicode })
        $overlap  = $oldNames | Where-Object { $newNames -contains $_ }

        if ($overlap) {
            Write-Host "Removing old certificate $tp (subject overlap: $($overlap -join ', '))"
            Remove-Item "Cert:\LocalMachine\My\$tp" -Force
        }
    }

    # RESTART

    switch ($RestartMode) {
        'Service' {
            Write-Host 'Restarting Active Directory Domain Services and Kerberos Key Distribution Center...'
            Restart-Service -Name 'NTDS'  -Force -ErrorAction Stop
            Restart-Service -Name 'kdc'   -Force -ErrorAction SilentlyContinue
            Write-Host "Services restarted. DC will now offer certificate $newThumbprint for LDAPS."
        }
        'Reboot' {
            Write-Warning 'ADRestartMode is set to Reboot. The system will restart in 15 seconds.'
            Write-Warning 'Press Ctrl+C to cancel.'
            Start-Sleep -Seconds 15
            Restart-Computer -Force
        }
    }
}

# STANDALONE LDAP

function Install-StandaloneLDAPCert {
    param(
        [string]$PfxPath,
        [SecureString]$PfxPassword,
        [string]$ServiceName
    )

    Write-Host "Installing certificate for standalone LDAP service '$ServiceName'..."

    # Import into the machine store so the service can access it.
    $imported   = Import-PfxCertificate `
        -FilePath          $PfxPath `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -Password          $PfxPassword `
        -ErrorAction       Stop

    Write-Host "Certificate imported. Thumbprint: $($imported.Thumbprint)"

    # The standalone LDAP service must be configured separately to point at this
    # certificate (e.g. via its own config file). This script only handles the
    # store import and service restart.

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Restarting service '$ServiceName'..."
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
        Write-Host "Service '$ServiceName' restarted."
    } else {
        Write-Warning "Service '$ServiceName' not found. Skipping restart - restart it manually."
    }
}
