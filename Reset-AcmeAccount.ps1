# ACME ACCOUNT RESET
# Removes the stored posh-acme account for the configured ACME server so that
# the next run of Invoke-CertRenewal.ps1 registers a fresh account.
#
# Usage:
#   .\Reset-AcmeAccount.ps1
#   .\Reset-AcmeAccount.ps1 -ConfigPath C:\path\to\config.ps1

#Requires -Version 5.1

param(
    [string]$ConfigPath = "$PSScriptRoot\config.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# LOAD CONFIGURATION

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}
. $ConfigPath

# LOAD POSH-ACME

if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
    throw "Posh-ACME module is not installed. Nothing to reset."
}
Import-Module Posh-ACME -ErrorAction Stop

# REMOVE ACCOUNT

Set-PAServer $AcmeServer

$account = Get-PAAccount -ErrorAction SilentlyContinue
if (-not $account) {
    Write-Host "No ACME account found for server $AcmeServer. Nothing to remove."
    exit 0
}

Write-Host "Removing ACME account $($account.id) ($($account.contact -join ', ')) from $AcmeServer..."
Remove-PAAccount $account.id -Force
Write-Host "Done. The next run of Invoke-CertRenewal.ps1 will register a new account."
