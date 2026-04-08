# SCHEDULED TASK REGISTRATION
# Creates a Windows scheduled task that runs Invoke-CertRenewal.ps1 automatically.
# Must be run as Administrator.
#
# Usage:
#   .\Register-ScheduledTask.ps1
#   .\Register-ScheduledTask.ps1 -TaskName 'MyCertRenewal' -TriggerHour 2

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [string]$TaskName      = 'ACME-CertRenewal',
    [string]$ScriptPath    = "$PSScriptRoot\Invoke-CertRenewal.ps1",

    # Account to run the task as. SYSTEM is recommended for unattended operation.
    # If using a service account, supply credentials when prompted.
    [string]$RunAsUser     = 'SYSTEM',

    # Hour of day (24h) to run the task. Default: 3 AM.
    [ValidateRange(0,23)]
    [int]$TriggerHour      = 3,

    # posh-acme only renews within 30 days of expiry by default, so daily is safe.
    [ValidateSet('Daily','Weekly')]
    [string]$Frequency     = 'Daily'
)

# VALIDATE SCRIPT PATH

if (-not (Test-Path $ScriptPath)) {
    throw "Script not found: $ScriptPath. Provide the correct path with -ScriptPath."
}

$fullScriptPath = (Resolve-Path $ScriptPath).Path

# TASK ACTION

$action = New-ScheduledTaskAction `
    -Execute  'powershell.exe' `
    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$fullScriptPath`""

# TASK TRIGGER

$triggerTime = '{0:D2}:00' -f $TriggerHour

switch ($Frequency) {
    'Daily'  { $trigger = New-ScheduledTaskTrigger -Daily  -At $triggerTime }
    'Weekly' { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $triggerTime }
}

# TASK SETTINGS

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit  (New-TimeSpan -Hours 1) `
    -RestartCount        2 `
    -RestartInterval     (New-TimeSpan -Minutes 30) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

# TASK PRINCIPAL

if ($RunAsUser -eq 'SYSTEM') {
    $principal = New-ScheduledTaskPrincipal `
        -UserId    'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel  Highest
} else {
    $cred = Get-Credential -UserName $RunAsUser -Message "Enter password for scheduled task account '$RunAsUser':"
    $principal = New-ScheduledTaskPrincipal `
        -UserId    $RunAsUser `
        -LogonType Password `
        -RunLevel  Highest

    # RegisteredTask requires the password when not using SYSTEM.
    # We register differently below in this case.
}

# REGISTER TASK

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Task '$TaskName' already exists. Updating..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

if ($RunAsUser -eq 'SYSTEM') {
    Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Description 'Automated Let''s Encrypt certificate renewal via posh-acme and PowerDNS.' | Out-Null
} else {
    Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -RunLevel  Highest `
        -User      $RunAsUser `
        -Password  $cred.GetNetworkCredential().Password `
        -Description 'Automated Let''s Encrypt certificate renewal via posh-acme and PowerDNS.' | Out-Null
}

Write-Host ''
Write-Host "Scheduled task '$TaskName' registered successfully."
Write-Host "  Script  : $fullScriptPath"
Write-Host "  Account : $RunAsUser"
Write-Host "  Trigger : $Frequency at $triggerTime"
Write-Host ''
Write-Host 'IMPORTANT: The first run must be done manually as the same account to register the ACME account.'
Write-Host "  Run: Start-ScheduledTask -TaskName '$TaskName'"
Write-Host '  Or open Task Scheduler and run it from there.'
