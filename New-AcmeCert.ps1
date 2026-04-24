# ACME CERTIFICATE ISSUANCE
# Handles posh-acme setup, account registration, and certificate issuance/renewal.
# Returns the posh-acme certificate object on success.

#Requires -Version 5.1

function Invoke-CertIssuance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Domains,
        [Parameter(Mandatory)][string]$ContactEmail,
        [Parameter(Mandatory)][string]$AcmeServer,
        [Parameter(Mandatory)][string]$PluginDir,
        [Parameter(Mandatory)][hashtable]$PluginArgs,
        [int]$DnsPropagationDelay = 30,
        [switch]$Force
    )

    # posh-acme accesses optional properties on ACME response objects that may not
    # always be present. Strict mode would turn those into hard errors.
    Set-StrictMode -Off

    # PS 5.1 may default to TLS 1.0. Enable TLS 1.2 if it is not already active.
    $tls12 = [Net.SecurityProtocolType]::Tls12
    if (-not ([Net.ServicePointManager]::SecurityProtocol -band $tls12)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    }

    # ENSURE MODULE

    if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
        Write-Host 'posh-acme not found. Installing from PSGallery...'
        Install-Module -Name Posh-ACME -Scope AllUsers -Force -AllowClobber
    }
    Import-Module Posh-ACME -ErrorAction Stop

    # REGISTER CUSTOM PLUGIN

    # posh-acme loads plugins from the DnsPlugins folder inside its module directory.
    # Copy our plugin there if it is not already current.
    $moduleBase  = (Get-Module Posh-ACME).ModuleBase
    $pluginDest  = Join-Path $moduleBase 'Plugins'

    if (-not (Test-Path $pluginDest)) {
        New-Item -ItemType Directory -Path $pluginDest | Out-Null
    }

    $srcPlugin  = Join-Path $PluginDir 'PowerDNS.ps1'
    $destPlugin = Join-Path $pluginDest 'PowerDNS.ps1'

    $needsCopy = $true
    if (Test-Path $destPlugin) {
        $srcHash  = (Get-FileHash $srcPlugin  -Algorithm SHA256).Hash
        $dstHash  = (Get-FileHash $destPlugin -Algorithm SHA256).Hash
        $needsCopy = ($srcHash -ne $dstHash)
    }

    if ($needsCopy) {
        Write-Host 'Copying PowerDNS plugin to posh-acme module...'
        Copy-Item -Path $srcPlugin -Destination $destPlugin -Force
    }

    # ACME SERVER

    $currentServer = Get-PAServer -ErrorAction SilentlyContinue
    if (-not $currentServer -or $currentServer.Name -ne $AcmeServer) {
        Write-Host "Setting ACME server to $AcmeServer..."
        Set-PAServer $AcmeServer
    }

    # ACME ACCOUNT

    $account = Get-PAAccount -ErrorAction SilentlyContinue
    if (-not $account) {
        Write-Host "Registering new ACME account for $ContactEmail..."
        New-PAAccount -Contact "mailto:$ContactEmail" -AcceptTOS
    } else {
        Write-Host "Using existing ACME account: $($account.id)"
    }

    # ISSUE OR RENEW CERTIFICATE

    $primaryDomain = $Domains[0]
    Write-Host "Requesting certificate for: $($Domains -join ', ')"

    $certParams = @{
        Domain          = $Domains
        Plugin          = 'PowerDNS'
        PluginArgs      = $PluginArgs
        DnsSleep        = $DnsPropagationDelay
        ErrorAction     = 'Stop'
    }

    if ($Force) {
        $certParams.Force = $true
    }

    try {
        New-PACertificate @certParams
    } catch {
        Write-Error "Certificate issuance failed: $_"
        throw
    }

    $cert = Get-PACertificate -MainDomain $primaryDomain
    if (-not $cert) {
        throw "Certificate issuance appeared to succeed but Get-PACertificate returned nothing."
    }

    Write-Host "Certificate issued. Thumbprint: $($cert.Thumbprint)"
    Write-Host "PFX path: $($cert.PfxFullChain)"

    return $cert
}
