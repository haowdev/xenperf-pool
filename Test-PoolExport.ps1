#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$exporter = Join-Path $PSScriptRoot 'Export-XenPoolPerfToElastic.ps1'
$temporaryFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$null = New-Item -ItemType Directory -Path $temporaryFolder
$testContext = @{
    Epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 10
    FailHost = ''
    RejectHost = ''
    Requests = [System.Collections.Generic.List[string]]::new()
    Documents = [System.Collections.Generic.List[object]]::new()
    Ids = [System.Collections.Generic.List[string]]::new()
    Disconnected = $false
    Connections = 0
    Disconnects = 0
    PoolCalls = 0
    InvalidAtPoolCall = 0
    StopAtPoolCall = 0
    StopFile = ''
    SessionIds = [System.Collections.Generic.List[string]]::new()
    ConnectionTlsBypass = [System.Collections.Generic.List[bool]]::new()
    HttpTlsBypass = [System.Collections.Generic.List[bool]]::new()
    RrdUnauthorizedRemaining = 0
    BulkUnauthorized = $false
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Import-Module { param($Name, $ErrorAction) }
function Connect-XenServer {
    param($Url, $UserName, $Password, [switch]$SetDefaultSession, [switch]$PassThru, [switch]$NoWarnCertificates)
    $testContext.Connections++
    $testContext.ConnectionTlsBypass.Add([bool]$NoWarnCertificates)
    [pscustomobject]@{ opaque_ref = "test-session-$($testContext.Connections)" }
}
function Get-XenPool {
    param($SessionOpaqueRef)
    $testContext.PoolCalls++
    if ($testContext.PoolCalls -eq $testContext.InvalidAtPoolCall) { throw 'SESSION_INVALID' }
    if ($testContext.PoolCalls -eq $testContext.StopAtPoolCall) {
        $null = New-Item -ItemType File -Path $testContext.StopFile
    }
    [pscustomobject]@{ uuid = 'pool-id' }
}
function Get-XenHost {
    param($SessionOpaqueRef)
    [pscustomobject]@{ opaque_ref = 'host-ref-a'; control_domain = 'dom0-host-a'; uuid = 'host-a'; address = 'host-a'; name_label = 'Host A' }
    [pscustomobject]@{ opaque_ref = 'host-ref-b'; control_domain = 'dom0-host-b'; uuid = 'host-b'; address = 'host-b'; name_label = 'Host B' }
}
function Get-XenVM {
    param($SessionOpaqueRef, $Ref)
    $vms = @(
        [pscustomobject]@{ uuid = 'vm-host-a'; name_label = 'Production VM A'; is_control_domain = $false }
        [pscustomobject]@{ uuid = 'dom0-host-a'; name_label = 'Control domain on Host A'; is_control_domain = $true; memory_static_max = 4479516672 }
        [pscustomobject]@{ uuid = 'vm-host-b'; name_label = 'Production VM B'; is_control_domain = $false }
        [pscustomobject]@{ uuid = 'dom0-host-b'; name_label = 'Control domain on Host B'; is_control_domain = $true; memory_static_max = 4479516672 }
    )
    if ($Ref) { return $vms | Where-Object { $_.uuid -eq [string]$Ref } }
    return $vms
}
function Disconnect-XenServer {
    $testContext.Disconnected = $true
    $testContext.Disconnects++
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec, [switch]$SkipCertificateCheck)
    $testContext.HttpTlsBypass.Add([bool]$SkipCertificateCheck)
    if ($Uri -like '*/rrd_updates?*') {
        $sourceHost = ([uri]$Uri).Host
        $testContext.Requests.Add($sourceHost)
        $sessionId = ([uri]$Uri).Query -replace '^.*session_id=([^&]+).*$', '$1'
        $testContext.SessionIds.Add($sessionId)
        if ($testContext.RrdUnauthorizedRemaining -gt 0) {
            $testContext.RrdUnauthorizedRemaining--
            throw '401 Unauthorized'
        }
        if ($sourceHost -eq $testContext.FailHost) { throw 'Simulated host outage' }
        if ($Uri -match '&uuid=([^&]+)') {
            $dom0Uuid = [uri]::UnescapeDataString($Matches[1])
            return "<xport><meta><legend><entry>AVERAGE:vm:${dom0Uuid}:cpu0</entry><entry>AVERAGE:vm:${dom0Uuid}:memory</entry><entry>AVERAGE:vm:${dom0Uuid}:memory_internal_free</entry></legend></meta><data><row><t>$($testContext.Epoch)</t><v>0.25</v><v>4294955008</v><v>2769876</v></row></data></xport>"
        }
        return "<xport><meta><legend><entry>AVERAGE:host:${sourceHost}:cpu0</entry><entry>AVERAGE:vm:vm-${sourceHost}:memory</entry><entry>AVERAGE:host:${sourceHost}:missing</entry></legend></meta><data><row><t>$($testContext.Epoch)</t><v>0.5</v><v>1024</v><v>NaN</v></row></data></xport>"
    }
    Assert-True ($Uri -eq 'https://elastic/_bulk') 'Unexpected bulk URL'
    if ($testContext.BulkUnauthorized) { throw '401 Unauthorized' }
    Assert-True ($Body.EndsWith("`n")) 'Bulk payload must end in a newline'
    $lines = $Body.TrimEnd("`n") -split "`n"
    $items = @(
        for ($position = 0; $position -lt $lines.Count; $position += 2) {
            $metadata = $lines[$position] | ConvertFrom-Json
            $document = $lines[$position + 1] | ConvertFrom-Json -AsHashtable
            $testContext.Ids.Add($metadata.index._id)
            $testContext.Documents.Add($document)
            if ($document['xen.host_uuid'] -eq $testContext.RejectHost) {
                @{ index = @{ status = 429; error = @{ reason = 'Simulated rejection' } } }
            } else { @{ index = @{ status = 201 } } }
        }
    )
    @{ errors = [bool]@($items | Where-Object { $_.index.error }).Count; items = $items }
}

$credential = [pscredential]::new('test', (ConvertTo-SecureString 'test-only' -AsPlainText -Force))
$parameters = @{ PoolMaster = 'master'; Credential = $credential; ElasticsearchUrl = 'https://elastic/'; SkipCertificateCheck = $true }
try {
    $statePath = Join-Path $temporaryFolder 'success.json'
    & $exporter @parameters -StateFile $statePath
    $state = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($testContext.Requests.Count -eq 4) 'Must query host and control-domain RRDs for both hosts'
    Assert-True ($testContext.Documents.Count -eq 12) 'Must export host, VM, and control-domain CPU/memory metrics, including derived memory usage percent and excluding NaN'
    Assert-True ($state.hosts.Count -eq 2) 'Must checkpoint each successful host'
    foreach ($document in $testContext.Documents) {
        Assert-True ($document['xen.pool_uuid'] -eq 'pool-id') 'Incorrect pool identity'
        Assert-True ($document['xen.object_uuid'] -like "*$($document['xen.host_uuid'])") 'Incorrect host attribution'
        if ($document['xen.object_type'] -eq 'vm') {
            Assert-True ($document['xen.object_name'] -like '*VM*' -or $document['xen.object_name'] -like 'Control domain*') 'VM UUID must be accompanied by its XenServer name'
        }
    }
    $dom0Documents = @($testContext.Documents | Where-Object { $_['xen.is_control_domain'] })
    Assert-True ($dom0Documents.Count -eq 8) 'Each host control domain must export CPU, memory, internal free memory, and derived usage percent'
    Assert-True (@($dom0Documents | Where-Object { $_['xen.metric'] -eq 'cpu0' }).Count -eq 2) 'Control-domain CPU samples are missing'
    Assert-True (@($dom0Documents | Where-Object { $_['xen.metric'] -eq 'memory' }).Count -eq 2) 'Control-domain memory samples are missing'
    $dom0MemoryUsage = @($dom0Documents | Where-Object { $_['xen.metric'] -eq 'dom0_memory_used_percent' })
    Assert-True ($dom0MemoryUsage.Count -eq 2) 'Derived control-domain memory usage percentage is missing'
    $expectedDom0MemoryUsage = (([double]4294955008 - 2769876) / 4479516672) * 100
    Assert-True (@($dom0MemoryUsage | Where-Object { [Math]::Abs($_.value - $expectedDom0MemoryUsage) -gt 0.0001 }).Count -eq 0) 'Control-domain memory usage percentage is incorrect at real memory sizes'
    $originalIds = @($testContext.Ids)
    $testContext.Ids.Clear()
    & $exporter @parameters -StateFile (Join-Path $temporaryFolder 'replay.json')
    Assert-True (($originalIds -join ',') -eq ($testContext.Ids -join ',')) 'Replay IDs must be deterministic'
    $testContext.Documents.Clear()
    & $exporter @parameters -StateFile $statePath
    Assert-True ($testContext.Documents.Count -eq 0) 'Already-checkpointed rows must not be sent again'

    foreach ($mode in @('FailHost', 'RejectHost')) {
        $testContext[$mode] = 'host-b'
        $failureState = Join-Path $temporaryFolder "$mode.json"
        $didThrow = $false
        try { & $exporter @parameters -StateFile $failureState } catch { $didThrow = $true }
        Assert-True $didThrow 'Partial failures must fail the run'
        $state = Get-Content $failureState -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($state.hosts.Contains('host-a')) 'Successful host checkpoint was lost'
        Assert-True ($state.hosts['host-a'] -eq $testContext.Epoch) 'Successful host checkpoint must advance'
        Assert-True ($state.hosts.Contains('host-b') -and $state.hosts['host-b'] -lt $testContext.Epoch) 'Failed host must retain its initial retry boundary'
        $testContext[$mode] = ''
        $testContext.Documents.Clear()
        & $exporter @parameters -StateFile $failureState
        Assert-True ($testContext.Documents.Count -eq 6) 'Retry must recover only the failed host and control-domain samples'
    }
    Assert-True $testContext.Disconnected 'Session must be disconnected'
    Write-Output 'PASS: all hosts, host/VM attribution, NaN filtering, replay IDs, incremental export, partial outages, and bulk rejection.'

    $runner = Join-Path $PSScriptRoot 'Run-ScheduledPoolExport.ps1'
    $credentialPath = Join-Path $temporaryFolder 'credential.clixml'
    $credential | Export-Clixml -LiteralPath $credentialPath
    $workerParams = @{
        PoolMaster = 'master'
        ElasticsearchUrl = 'https://elastic/'
        CredentialFile = $credentialPath
        Continuous = $true
        PollSeconds = 1
        LogFile = ''
        StopFile = Join-Path $temporaryFolder 'worker.stop'
    }
    foreach ($scenario in @('reuse', 'expired', 'rrd-unauthorized', 'bulk-error', 'bulk-unauthorized', 'insecure', 'stop')) {
        $testContext.Connections = 0
        $testContext.Disconnects = 0
        $testContext.PoolCalls = 0
        $testContext.SessionIds.Clear()
        $testContext.ConnectionTlsBypass.Clear()
        $testContext.HttpTlsBypass.Clear()
        $testContext.InvalidAtPoolCall = 0
        $testContext.StopAtPoolCall = 0
        $testContext.StopFile = $workerParams.StopFile
        $workerParams.SkipCertificateCheck = ($scenario -eq 'insecure')
        if ($scenario -eq 'expired') { $testContext.InvalidAtPoolCall = 2 }
        if ($scenario -eq 'rrd-unauthorized') { $testContext.RrdUnauthorizedRemaining = 1 }
        if ($scenario -eq 'bulk-error') { $testContext.RejectHost = 'host-b' }
        $testContext.BulkUnauthorized = ($scenario -eq 'bulk-unauthorized')
        if ($scenario -eq 'stop') { $testContext.StopAtPoolCall = 1 }
        $expectedFailure = $false
        try {
            & $runner @workerParams -MaxCycles 3 -StateFile (Join-Path $temporaryFolder "$scenario.json")
        } catch { $expectedFailure = $true }
        Assert-True ($expectedFailure -eq ($scenario -in @('bulk-error', 'bulk-unauthorized'))) "Unexpected worker outcome: $scenario"
        $expectedConnections = if ($scenario -in @('expired', 'rrd-unauthorized')) { 2 } else { 1 }
        Assert-True ($testContext.Connections -eq $expectedConnections) "Incorrect login count: $scenario"
        Assert-True ($testContext.Disconnects -eq $expectedConnections) "Session cleanup failed: $scenario"
        Assert-True (@($testContext.ConnectionTlsBypass | Where-Object { $_ -ne $workerParams.SkipCertificateCheck }).Count -eq 0) "Incorrect connection TLS setting: $scenario"
        Assert-True (@($testContext.HttpTlsBypass | Where-Object { $_ -ne $workerParams.SkipCertificateCheck }).Count -eq 0) "Incorrect HTTP TLS setting: $scenario"
        if ($scenario -eq 'reuse') {
            Assert-True ($testContext.PoolCalls -eq 3) 'Worker must complete three cycles'
            Assert-True (@($testContext.SessionIds | Sort-Object -Unique).Count -eq 1) 'Cycles must reuse the same session token'
        }
        if ($scenario -eq 'stop') {
            Assert-True ($testContext.PoolCalls -eq 1) 'Stop signal must prevent another cycle'
        }
        $testContext.RejectHost = ''
    }
    Write-Output 'PASS: persistent session reuse, expired/RRD-401 reconnect, no relogin on Elasticsearch errors/401, TLS defaults and opt-in bypass, bounded runs, and graceful stop cleanup.'
} finally {
    Remove-Item -LiteralPath $temporaryFolder -Recurse -Force
}