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
    $beforeThumbprints = @(Get-ChildItem 'Cert:\LocalMachine\My' | Select-Object -ExpandProperty Thumbprint)

    $imported = @(Import-PfxCertificate `
        -FilePath          $PfxPath `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -Password          $PfxPassword `
        -ErrorAction       Stop)

    # Full-chain PFX files return multiple objects (end-entity + intermediates).
    # Only the end-entity cert has a private key.
    $endEntity = $imported | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    if (-not $endEntity) { $endEntity = $imported[0] }
    $newThumbprint = $endEntity.Thumbprint
    Write-Host "Certificate imported. Thumbprint: $newThumbprint"

    # REMOVE OLD MATCHING CERTIFICATES
    # Find certs that were present before the import and share at least one Subject name
    # with the new cert. These are candidates the DC would otherwise compete with.

    $newNames = @($endEntity.DnsNameList | ForEach-Object { $_.Unicode })

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

            # NTDS reports Running before the LDAPS listener is ready.
            # Poll port 636 until it accepts connections (up to 120s).
            Write-Host 'Waiting for LDAPS listener on port 636...'
            $deadline = (Get-Date).AddSeconds(120)
            $ready    = $false
            while ((Get-Date) -lt $deadline) {
                $tcp = Test-NetConnection -ComputerName localhost -Port 636 -WarningAction SilentlyContinue -InformationLevel Quiet
                if ($tcp) { $ready = $true; break }
                Start-Sleep -Seconds 5
            }

            if ($ready) {
                Write-Host "LDAPS listener ready. DC will now offer certificate $newThumbprint for LDAPS."
            } else {
                Write-Warning "LDAPS listener did not come up within 120s. The certificate is installed — LDAPS may need more time or a reboot."
            }
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
    $imported  = @(Import-PfxCertificate `
        -FilePath          $PfxPath `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -Password          $PfxPassword `
        -ErrorAction       Stop)
    $endEntity = $imported | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    if (-not $endEntity) { $endEntity = $imported[0] }

    Write-Host "Certificate imported. Thumbprint: $($endEntity.Thumbprint)"

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
