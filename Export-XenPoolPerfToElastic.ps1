#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PoolMaster,

    [Parameter(Mandatory)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory)]
    [string]$ElasticsearchUrl,

    [string]$ElasticsearchApiKey,

    [ValidateRange(1, 86400)]
    [int]$IntervalSeconds = 60,

    [string]$StateFile = (Join-Path $PSScriptRoot 'xenperf-pool.state.json'),

    [object]$Session,

    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
Import-Module XenServerPSModule -ErrorAction Stop
$httpParams = @{ TimeoutSec = 60 }
if ($SkipCertificateCheck) { $httpParams.SkipCertificateCheck = $true }

function ConvertTo-PoolMetricDocs {
    param([xml]$Xport, [string]$HostUuid, [string]$HostName, [string]$PoolUuid, [long]$Since)

    if (-not $Xport.xport.meta -or -not $Xport.xport.data) {
        throw 'Invalid RRD response: expected xport metadata and data.'
    }
    $entries = @($Xport.xport.meta.legend.entry)
    foreach ($row in $Xport.xport.data.row) {
        $epoch = [long]$row.t
        if ($epoch -le $Since) { continue }
        $values = @($row.v)
        if ($values.Count -ne $entries.Count) { throw 'RRD legend/value count mismatch.' }
        for ($position = 0; $position -lt $entries.Count; $position++) {
            $parts = $entries[$position] -split ':', 4
            if ($parts.Count -ne 4) { throw 'Invalid RRD legend entry.' }
            $raw = [string]$values[$position]
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $value = [double]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { continue }
            @{
                '@timestamp' = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime.ToString('o')
                'xen.pool_uuid' = $PoolUuid
                'xen.host_uuid' = $HostUuid
                'xen.host_name' = $HostName
                'xen.object_type' = $parts[1]
                'xen.object_uuid' = $parts[2]
                'xen.metric' = $parts[3]
                'xen.cf' = $parts[0]
                'xen.ts_epoch' = $epoch
                'value' = $value
            }
        }
    }
}

function Send-PoolMetrics {
    param([hashtable[]]$Docs)

    $headers = @{}
    if ($ElasticsearchApiKey) { $headers.Authorization = "ApiKey $ElasticsearchApiKey" }
    for ($start = 0; $start -lt $Docs.Count; $start += 2000) {
        $payload = [System.Text.StringBuilder]::new()
        $end = [Math]::Min($start + 2000, $Docs.Count)
        for ($position = $start; $position -lt $end; $position++) {
            $doc = $Docs[$position]
            $identity = '{0}|{1}|{2}|{3}|{4}|{5}' -f $doc['xen.pool_uuid'], $doc['xen.host_uuid'], $doc['xen.object_uuid'], $doc['xen.metric'], $doc['xen.cf'], $doc['xen.ts_epoch']
            $hash = [System.Security.Cryptography.SHA256]::Create()
            try {
                $docId = [BitConverter]::ToString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($identity))).Replace('-', '').ToLowerInvariant()
            } finally { $hash.Dispose() }
            $date = [DateTimeOffset]::FromUnixTimeSeconds($doc['xen.ts_epoch']).UtcDateTime.ToString('yyyy.MM.dd')
            $meta = @{ index = @{ _index = "xenserver-metrics-$date"; _id = $docId } }
            [void]$payload.Append(($meta | ConvertTo-Json -Compress)).Append("`n")
            [void]$payload.Append(($doc | ConvertTo-Json -Compress)).Append("`n")
        }
        $response = Invoke-RestMethod -Uri "$($ElasticsearchUrl.TrimEnd('/'))/_bulk" -Method Post -Headers $headers -ContentType 'application/x-ndjson' -Body $payload.ToString() @httpParams
        $items = @($response.items)
        $failed = @($items | Where-Object { $_.index.error -or $_.index.status -lt 200 -or $_.index.status -ge 300 })
        if ($response.errors -or $failed.Count -or $items.Count -ne ($end - $start)) {
            throw "Elasticsearch bulk write failed: $(($failed | Select-Object -First 3) | ConvertTo-Json -Depth 8 -Compress)"
        }
    }
}

$state = @{ hosts = @{} }
if (Test-Path -LiteralPath $StateFile) {
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -AsHashtable
    if ($state.hosts -isnot [System.Collections.IDictionary]) { throw 'Invalid pool checkpoint file.' }
}
$ownsSession = -not $Session
$failures = [System.Collections.Generic.List[string]]::new()
$sessionInvalid = $false
$total = 0
try {
    if ($ownsSession) {
        $connectParams = @{
            Url = "https://$PoolMaster"
            UserName = $Credential.UserName
            Password = $Credential.GetNetworkCredential().Password
            SetDefaultSession = $true
            PassThru = $true
        }
        if ($SkipCertificateCheck) { $connectParams.NoWarnCertificates = $true }
        $Session = Connect-XenServer @connectParams
    }
    $pools = @(Get-XenPool -SessionOpaqueRef $Session.opaque_ref)
    if ($pools.Count -ne 1) { throw 'Expected exactly one XenServer pool.' }
    $poolUuid = $pools[0].uuid
    $hosts = @(Get-XenHost -SessionOpaqueRef $Session.opaque_ref)
    if (-not $hosts.Count) { throw 'No hosts were discovered in the pool.' }
    $initialSince = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $IntervalSeconds
    foreach ($poolHost in $hosts) {
        if ($poolHost.uuid -and -not $state.hosts.Contains([string]$poolHost.uuid)) {
            $state.hosts[[string]$poolHost.uuid] = $initialSince
        }
    }
    $temporaryState = "$StateFile.tmp"
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryState -Encoding utf8
    Move-Item -LiteralPath $temporaryState -Destination $StateFile -Force
    foreach ($poolHost in $hosts) {
        try {
            if (-not $poolHost.address -or -not $poolHost.uuid) { throw 'Host has no management address or UUID.' }
            $hostUuid = [string]$poolHost.uuid
            $since = [long]$state.hosts[$hostUuid]
            $sessionId = [uri]::EscapeDataString($session.opaque_ref)
            $uri = "https://$($poolHost.address)/rrd_updates?session_id=$sessionId&start=$since&cf=AVERAGE&interval=$IntervalSeconds&host=true"
            $stage = 'RRD'
            [xml]$xport = Invoke-RestMethod -Uri $uri @httpParams
            $stage = 'Index'
            $docs = @(ConvertTo-PoolMetricDocs -Xport $xport -HostUuid $hostUuid -HostName $poolHost.name_label -PoolUuid $poolUuid -Since $since)
            Write-Verbose "Host $($poolHost.name_label): collected $($docs.Count) data points; sending to Elasticsearch."
            Send-PoolMetrics -Docs $docs
            if ($docs.Count) {
                $latest = ($docs | Measure-Object -Property 'xen.ts_epoch' -Maximum).Maximum
                $state.hosts[$hostUuid] = [long]$latest
                try {
                    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryState -Encoding utf8
                    Move-Item -LiteralPath $temporaryState -Destination $StateFile -Force
                } catch {
                    $state.hosts[$hostUuid] = $since
                    throw
                }
            }
            $total += $docs.Count
            Write-Host "Host $($poolHost.name_label) ($($poolHost.address)): exported $($docs.Count) data points."
        } catch {
            if ($stage -eq 'RRD' -and ($_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::Unauthorized -or $_.Exception.Message -match '(?i)\b401\b|\bSESSION_INVALID\b')) {
                $sessionInvalid = $true
            }
            $failures.Add("Host $($poolHost.name_label) ($($poolHost.address)): $($_.Exception.Message)")
            Write-Warning $failures[-1]
        }
    }
    if ($failures.Count) {
        $failure = [System.InvalidOperationException]::new("Pool export incomplete: $($failures.Count) host(s) failed. Successful hosts: $($hosts.Count - $failures.Count). $($failures -join '; ')")
        $failure.Data['XenSessionInvalid'] = $sessionInvalid
        throw $failure
    }
    Write-Host "Exported $total data points from $($hosts.Count) hosts to Elasticsearch."
} finally {
    if ($ownsSession -and $Session) { $Session | Disconnect-XenServer -ErrorAction SilentlyContinue }
}