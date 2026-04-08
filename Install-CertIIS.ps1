# IIS CERTIFICATE INSTALLATION
# Imports a certificate into the Local Machine store and binds it to an IIS site.

#Requires -Version 5.1
#Requires -RunAsAdministrator

function Install-CertToIIS {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PfxPath,
        [Parameter(Mandatory)][string]$PfxPassword,
        [Parameter(Mandatory)][string]$SiteName,
        [string]$BindingPort  = '443',
        [string]$HostHeader   = ''
    )

    # IMPORT MODULE

    if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
        throw 'WebAdministration module not found. Ensure IIS Management Tools are installed.'
    }
    Import-Module WebAdministration -ErrorAction Stop

    # IMPORT CERTIFICATE INTO STORE

    Write-Host "Importing certificate from $PfxPath..."

    $securePass = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
    $imported   = Import-PfxCertificate `
        -FilePath      $PfxPath `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -Password      $securePass `
        -ErrorAction   Stop

    $thumbprint = $imported.Thumbprint
    Write-Host "Certificate imported. Thumbprint: $thumbprint"

    # FIND BINDING

    $site = Get-WebSite -Name $SiteName -ErrorAction SilentlyContinue
    if (-not $site) {
        throw "IIS site '$SiteName' not found."
    }

    # Build the binding information string: IP:port:hostheader
    $bindingInfo = "*:${BindingPort}:${HostHeader}"

    $binding = Get-WebBinding -Name $SiteName -Protocol 'https' |
        Where-Object { $_.bindingInformation -eq $bindingInfo }

    if (-not $binding) {
        Write-Host "No existing HTTPS binding found for $bindingInfo. Creating one..."
        New-WebBinding -Name $SiteName -Protocol 'https' -Port $BindingPort -HostHeader $HostHeader
        $binding = Get-WebBinding -Name $SiteName -Protocol 'https' |
            Where-Object { $_.bindingInformation -eq $bindingInfo }
    }

    # ASSIGN CERTIFICATE
    # Remove any existing SSL certificate on the binding first.
    # AddSslCertificate throws if a cert is already assigned.

    try {
        $binding.DeleteSslCertificate()
        Write-Host 'Removed existing SSL certificate from binding.'
    } catch {
        # No cert was assigned yet — safe to continue.
    }

    $binding.AddSslCertificate($thumbprint, 'My')
    Write-Host "Certificate $thumbprint bound to site '$SiteName' on port $BindingPort."
}
