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

    $tls12 = [Net.SecurityProtocolType]::Tls12
    if (-not ([Net.ServicePointManager]::SecurityProtocol -band $tls12)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    }

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

function Wait-DnsPropagation {
    param(
        [string]$RecordName,
        [string]$TxtValue,
        [string]$ZoneName,
        [int]$TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) { return }

    $bare = $RecordName.TrimEnd('.')

    try {
        $nsResults = Resolve-DnsName -Name $ZoneName -Type NS -ErrorAction Stop
        $nsHosts   = @($nsResults | Where-Object { $_.Type -eq 'NS' } | ForEach-Object { $_.NameHost })
    } catch {
        Write-Warning "Could not resolve NS records for ${ZoneName}: $_. Skipping propagation check."
        return
    }

    if ($nsHosts.Count -eq 0) {
        Write-Warning "No NS records found for ${ZoneName}. Skipping propagation check."
        return
    }

    Write-Host "Waiting for TXT record to propagate to $($nsHosts.Count) nameserver(s): $($nsHosts -join ', ')"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $start    = Get-Date

    while ((Get-Date) -lt $deadline) {
        $allSeen = $true
        foreach ($ns in $nsHosts) {
            try {
                $results = Resolve-DnsName -Name $bare -Type TXT -Server $ns -ErrorAction Stop
                $found   = $results | Where-Object { $_.Type -eq 'TXT' -and $_.Strings -contains $TxtValue }
                if (-not $found) { $allSeen = $false; break }
            } catch {
                $allSeen = $false; break
            }
        }

        if ($allSeen) {
            Write-Host "DNS propagation complete ($([int]((Get-Date) - $start).TotalSeconds)s)."
            return
        }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        Write-Host "  [${elapsed}s] Not yet visible on all nameservers. Retrying in 15s..."
        Start-Sleep -Seconds 15
    }

    Write-Warning "DNS propagation check timed out after ${TimeoutSeconds}s. Proceeding anyway."
}

# PLUGIN CONTRACT FUNCTIONS

function Add-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecordName,
        [Parameter(Mandatory)][string]$TxtValue,
        [Parameter(Mandatory)][string]$PdnsBaseUrl,
        [Parameter(Mandatory)][string]$PdnsApiKey,
        [string]$PdnsServerId          = 'localhost',
        [bool]$PdnsSkipSslVerify       = $false,
        [int]$PdnsPropagationTimeout   = 0
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
            $allRecords = @($existing.records | ForEach-Object { @{ content = $_.content; disabled = $false } })
        }
    } catch {
        $allRecords = @()
    }

    # Add the new TXT value if not already present.
    $quoted = "`"$TxtValue`""
    if ($allRecords | Where-Object { $_.content -eq $quoted }) {
        Write-Verbose "TXT record '$TxtValue' already present on $fqdn - skipping add."
    } else {
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

    Wait-DnsPropagation -RecordName $RecordName -TxtValue $TxtValue `
        -ZoneName $zoneName -TimeoutSeconds $PdnsPropagationTimeout
}

function Remove-DnsTxt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecordName,
        [Parameter(Mandatory)][string]$TxtValue,
        [Parameter(Mandatory)][string]$PdnsBaseUrl,
        [Parameter(Mandatory)][string]$PdnsApiKey,
        [string]$PdnsServerId          = 'localhost',
        [bool]$PdnsSkipSslVerify       = $false,
        [int]$PdnsPropagationTimeout   = 0
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
        Write-Verbose "No TXT records found for $fqdn - nothing to remove."
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
        [string]$PdnsServerId          = 'localhost',
        [bool]$PdnsSkipSslVerify       = $false,
        [int]$PdnsPropagationTimeout   = 0
    )
    # PowerDNS applies PATCH changes immediately; nothing to flush.
    Write-Verbose "Save-DnsTxt: PowerDNS applies changes immediately, no flush required."
}
