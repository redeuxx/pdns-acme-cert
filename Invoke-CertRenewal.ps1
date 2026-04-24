# CERTIFICATE RENEWAL ORCHESTRATOR
# Entry point for automated certificate issuance and installation.
# Run directly or via scheduled task.
#
# Usage:
#   .\Invoke-CertRenewal.ps1
#   .\Invoke-CertRenewal.ps1 -Force        # Skip posh-acme's renewal window check
#   .\Invoke-CertRenewal.ps1 -ConfigPath C:\path\to\config.ps1

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [string]$ConfigPath = "$PSScriptRoot\config.ps1",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# LOAD CONFIGURATION

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}
. $ConfigPath

# DOT-SOURCE SCRIPTS

. "$PSScriptRoot\New-AcmeCert.ps1"
. "$PSScriptRoot\Install-CertIIS.ps1"
. "$PSScriptRoot\Install-CertLDAP.ps1"
. "$PSScriptRoot\Send-Notification.ps1"

# BUILD PLUGIN ARGS

$pluginArgs = @{
    PdnsBaseUrl       = $PdnsBaseUrl
    PdnsApiKey        = $PdnsApiKey
    PdnsServerId      = $PdnsServerId
    PdnsSkipSslVerify = $PdnsSkipSslVerify
}

$notifyParams = @{
    Domains      = $Domains
    SmtpServer   = $SmtpServer
    SmtpPort     = $SmtpPort
    SmtpUseSsl   = $SmtpUseSsl
    SmtpUsername = $SmtpUsername
    SmtpPassword = $SmtpPassword
    EmailFrom    = $EmailFrom
    EmailTo      = $EmailTo
}

# ISSUE CERTIFICATE

Write-Host '=== ACME CERTIFICATE RENEWAL ==='
Write-Host "Domains  : $($Domains -join ', ')"
Write-Host "Target   : $CertTarget"
Write-Host "Server   : $AcmeServer"

$issueParams = @{
    Domains               = $Domains
    ContactEmail          = $ContactEmail
    AcmeServer            = $AcmeServer
    PluginDir             = "$PSScriptRoot\Plugins"
    PluginArgs            = $pluginArgs
    DnsPropagationDelay   = $DnsPropagationDelay
}
if ($Force) { $issueParams.Force = $true }

try {
    $cert = Invoke-CertIssuance @issueParams
} catch {
    Send-CertNotification @notifyParams -Status Failure -ErrorMessage $_.ToString()
    throw
}

# posh-acme exports PFX files with no password by default.
$pfxPassword = New-Object System.Security.SecureString
$pfxPath     = [string]$cert.PfxFullChain

# INSTALL CERTIFICATE

try {
    switch ($CertTarget) {
        'IIS' {
            Install-CertToIIS `
                -PfxPath     $pfxPath `
                -PfxPassword $pfxPassword `
                -SiteName    $IISSiteName `
                -BindingPort $IISBindingPort `
                -HostHeader  $IISHostHeader
        }
        'LDAP' {
            Install-CertToLDAP `
                -PfxPath         $pfxPath `
                -PfxPassword     $pfxPassword `
                -LdapType        $LdapType `
                -LdapServiceName $LdapServiceName `
                -ADRestartMode   $ADRestartMode
        }
        default {
            throw "Unknown CertTarget '$CertTarget'. Valid values: IIS, LDAP"
        }
    }
} catch {
    Send-CertNotification @notifyParams -Status Failure -ErrorMessage $_.ToString()
    throw
}

Send-CertNotification @notifyParams -Status Success `
    -Thumbprint $cert.Thumbprint `
    -Expiry     $cert.NotAfter

Write-Host '=== RENEWAL COMPLETE ==='
