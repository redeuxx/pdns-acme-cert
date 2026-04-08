# POSH-ACME CUSTOM DNS PLUGIN - POWERDNS
# Implements the Add-DnsTxt / Remove-DnsTxt / Save-DnsTxt contract required by posh-acme.
# Plugin parameters are passed via -PluginArgs hashtable in New-PACertificate.

# HELPERS

function Invoke-PdnsApi {
    param(
        [string]$Method,
        [string]$Url,
        [string]$ApiKey,
        [object]$Body = $null,
        [bool]$SkipSslVerify = $false
    )

    # PS 5.1 has no -SkipCertificateCheck on Invoke-RestMethod.
    # Use the ServicePointManager callback when SSL verification is disabled.
    if ($SkipSslVerify) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $params = @{
        Method      = $Method
        Uri         = $Url
        Headers     = @{
            'X-API-Key'    = $ApiKey
            'Content-Type' = 'application/json'
        }
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        Invoke-RestMethod @params
    }
    finally {
        # Always restore certificate validation to avoid leaking the bypass.
        if ($SkipSslVerify) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        }
    }
}

function Get-PdnsZone {
    param(
        [string]$RecordName,
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$ServerId,
        [bool]$SkipSslVerify
    )

    # Fetch all zones and find the longest matching suffix for $RecordName.
    $url   = "$BaseUrl/api/v1/servers/$ServerId/zones"
    $zones = Invoke-PdnsApi -Method GET -Url $url -ApiKey $ApiKey -SkipSslVerify $SkipSslVerify

    $best = $null
    foreach ($zone in $zones) {
        # Zone names from PowerDNS include a trailing dot; strip it for comparison.
        $zoneName = $zone.name.TrimEnd('.')
        if ($RecordName -like "*.$zoneName" -or $RecordName -eq $zoneName) {
            if ($null -eq $best -or $zoneName.Length -gt $best.Length) {
                $best = $zoneName
            }
        }
    }

    if (-not $best) {
        throw "No PowerDNS zone found that matches record '$RecordName'."
    }

    return $best
}

# PLUGIN CONTRACT FUNCTIONS

function Add-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecordName,
        [Parameter(Mandatory)][string]$TxtValue,
        [Parameter(Mandatory)][string]$PdnsBaseUrl,
        [Parameter(Mandatory)][string]$PdnsApiKey,
        [string]$PdnsServerId    = 'localhost',
        [bool]$PdnsSkipSslVerify = $false
    )

    # Ensure fully-qualified record name.
    $fqdn = if ($RecordName.EndsWith('.')) { $RecordName } else { "$RecordName." }

    $zoneName = Get-PdnsZone -RecordName $RecordName `
        -BaseUrl $PdnsBaseUrl -ApiKey $PdnsApiKey `
        -ServerId $PdnsServerId -SkipSslVerify $PdnsSkipSslVerify

    $url = "$PdnsBaseUrl/api/v1/servers/$PdnsServerId/zones/$zoneName"

    # Fetch current records for this name/type so we can preserve existing TXT values (SAN certs).
    try {
        $zone        = Invoke-PdnsApi -Method GET -Url "$url`?rrsets=true" `
                           -ApiKey $PdnsApiKey -SkipSslVerify $PdnsSkipSslVerify
        $existing    = $zone.rrsets | Where-Object { $_.name -eq $fqdn -and $_.type -eq 'TXT' }
        $allRecords  = @()
        if ($existing) {
            $allRecords = $existing.records | ForEach-Object { @{ content = $_.content; disabled = $false } }
        }
    } catch {
        $allRecords = @()
    }

    # Add the new TXT value if not already present.
    $quoted = "`"$TxtValue`""
    if ($allRecords | Where-Object { $_.content -eq $quoted }) {
        Write-Verbose "TXT record '$TxtValue' already present on $fqdn — skipping add."
        return
    }
    $allRecords += @{ content = $quoted; disabled = $false }

    $patch = @{
        rrsets = @(
            @{
                name       = $fqdn
                type       = 'TXT'
                ttl        = 60
                changetype = 'REPLACE'
                records    = $allRecords
            }
        )
    }

    Invoke-PdnsApi -Method PATCH -Url $url -ApiKey $PdnsApiKey `
        -Body $patch -SkipSslVerify $PdnsSkipSslVerify | Out-Null

    Write-Verbose "Added TXT record: $fqdn = $TxtValue"
}

function Remove-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecordName,
        [Parameter(Mandatory)][string]$TxtValue,
        [Parameter(Mandatory)][string]$PdnsBaseUrl,
        [Parameter(Mandatory)][string]$PdnsApiKey,
        [string]$PdnsServerId    = 'localhost',
        [bool]$PdnsSkipSslVerify = $false
    )

    $fqdn = if ($RecordName.EndsWith('.')) { $RecordName } else { "$RecordName." }

    $zoneName = Get-PdnsZone -RecordName $RecordName `
        -BaseUrl $PdnsBaseUrl -ApiKey $PdnsApiKey `
        -ServerId $PdnsServerId -SkipSslVerify $PdnsSkipSslVerify

    $url  = "$PdnsBaseUrl/api/v1/servers/$PdnsServerId/zones/$zoneName"
    $zone = Invoke-PdnsApi -Method GET -Url "$url`?rrsets=true" `
                -ApiKey $PdnsApiKey -SkipSslVerify $PdnsSkipSslVerify

    $existing = $zone.rrsets | Where-Object { $_.name -eq $fqdn -and $_.type -eq 'TXT' }
    if (-not $existing) {
        Write-Verbose "No TXT records found for $fqdn — nothing to remove."
        return
    }

    $quoted     = "`"$TxtValue`""
    $remaining  = $existing.records | Where-Object { $_.content -ne $quoted } |
                      ForEach-Object { @{ content = $_.content; disabled = $false } }

    if ($remaining.Count -eq 0) {
        # Delete the whole RRset.
        $patch = @{
            rrsets = @(
                @{
                    name       = $fqdn
                    type       = 'TXT'
                    changetype = 'DELETE'
                }
            )
        }
    } else {
        # Replace with remaining values.
        $patch = @{
            rrsets = @(
                @{
                    name       = $fqdn
                    type       = 'TXT'
                    ttl        = 60
                    changetype = 'REPLACE'
                    records    = $remaining
                }
            )
        }
    }

    Invoke-PdnsApi -Method PATCH -Url $url -ApiKey $PdnsApiKey `
        -Body $patch -SkipSslVerify $PdnsSkipSslVerify | Out-Null

    Write-Verbose "Removed TXT record: $fqdn = $TxtValue"
}

function Save-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PdnsBaseUrl,
        [Parameter(Mandatory)][string]$PdnsApiKey,
        [string]$PdnsServerId    = 'localhost',
        [bool]$PdnsSkipSslVerify = $false
    )
    # PowerDNS applies PATCH changes immediately; nothing to flush.
    Write-Verbose "Save-DnsTxt: PowerDNS applies changes immediately, no flush required."
}
