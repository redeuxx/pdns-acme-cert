# EMAIL NOTIFICATION
# Sends a success or failure email after a certificate renewal attempt.

#Requires -Version 5.1

function Send-CertNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success','Failure')]
        [string]$Status,

        [Parameter(Mandatory)][string[]]$Domains,
        [Parameter(Mandatory)][string]$SmtpServer,
        [Parameter(Mandatory)][int]$SmtpPort,
        [Parameter(Mandatory)][bool]$SmtpUseSsl,
        [string]$SmtpUsername,
        [string]$SmtpPassword,
        [Parameter(Mandatory)][string]$EmailFrom,
        [Parameter(Mandatory)][string[]]$EmailTo,

        # Populated on success
        [string]$Thumbprint,
        [datetime]$Expiry,

        # Populated on failure
        [string]$ErrorMessage
    )

    $domainList = $Domains -join ', '
    $hostname   = $env:COMPUTERNAME

    switch ($Status) {
        'Success' {
            $subject = "Certificate renewed: $domainList"
            $body    = @"
Certificate renewal succeeded on $hostname.

Domains    : $domainList
Thumbprint : $Thumbprint
Expires    : $($Expiry.ToString('yyyy-MM-dd'))
"@
        }
        'Failure' {
            $subject = "Certificate renewal FAILED: $domainList"
            $body    = @"
Certificate renewal failed on $hostname.

Domains : $domainList
Error   : $ErrorMessage
"@
        }
    }

    $mailParams = @{
        SmtpServer  = $SmtpServer
        Port        = $SmtpPort
        UseSsl      = $SmtpUseSsl
        From        = $EmailFrom
        To          = $EmailTo
        Subject     = $subject
        Body        = $body
        ErrorAction = 'Stop'
    }

    if ($SmtpUsername -and $SmtpPassword) {
        $securePass  = ConvertTo-SecureString $SmtpPassword -AsPlainText -Force
        $credential  = New-Object System.Management.Automation.PSCredential($SmtpUsername, $securePass)
        $mailParams.Credential = $credential
    }

    try {
        Send-MailMessage @mailParams
        Write-Host "Notification email sent to: $($EmailTo -join ', ')"
    } catch {
        # Never let a notification failure crash the main script.
        Write-Warning "Failed to send notification email: $_"
    }
}
