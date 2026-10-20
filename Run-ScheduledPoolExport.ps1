#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PoolMaster,
    [Parameter(Mandatory)]
    [string]$ElasticsearchUrl,
    [string]$CredentialFile = (Join-Path $PSScriptRoot 'xenserver-cred.clixml'),
    [string]$ElasticsearchApiKey = $env:ES_API_KEY,
    [ValidateRange(1, 86400)]
    [int]$IntervalSeconds = 60,
    [string]$StateFile = (Join-Path $PSScriptRoot 'xenperf-pool.state.json'),
    [switch]$Continuous,
    [ValidateRange(1, 86400)]
    [int]$PollSeconds = 60,
    [ValidateRange(0, 2147483647)]
    [int]$MaxCycles = 0,
    [string]$StopFile = (Join-Path $PSScriptRoot 'xenperf-pool.stop'),
    [string]$LogFile = (Join-Path $PSScriptRoot 'xenperf-pool.log'),
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw "Credential file not found: $CredentialFile. Create it using Get-Credential and Export-Clixml as described in README.md."
}
$exportParams = @{
    PoolMaster = $PoolMaster
    Credential = Import-Clixml -LiteralPath $CredentialFile
    ElasticsearchUrl = $ElasticsearchUrl
    ElasticsearchApiKey = $ElasticsearchApiKey
    IntervalSeconds = $IntervalSeconds
    StateFile = $StateFile
    SkipCertificateCheck = $SkipCertificateCheck
}
$exporter = Join-Path $PSScriptRoot 'Export-XenPoolPerfToElastic.ps1'
if (-not $Continuous) {
    & $exporter @exportParams
    return
}

Import-Module XenServerPSModule -ErrorAction Stop
$session = $null
$cycle = 0
$transcribing = $false
$waitHandle = [System.Threading.ManualResetEventSlim]::new($false)
try {
    if ($LogFile) {
        $null = Start-Transcript -LiteralPath $LogFile -Append
        $transcribing = $true
    }
    while (-not (Test-Path -LiteralPath $StopFile)) {
        $cycle++
        $lastError = $null
        try {
            if (-not $session) {
                $connectParams = @{
                    Url = "https://$PoolMaster"
                    UserName = $exportParams.Credential.UserName
                    Password = $exportParams.Credential.GetNetworkCredential().Password
                    SetDefaultSession = $true
                    PassThru = $true
                }
                if ($SkipCertificateCheck) { $connectParams.NoWarnCertificates = $true }
                $session = Connect-XenServer @connectParams
                Write-Host "Opened XenServer session to $PoolMaster."
            }
            & $exporter @exportParams -Session $session
            Write-Host "Cycle $cycle completed at $([DateTimeOffset]::UtcNow.ToString('o'))."
        } catch {
            $lastError = $_
            $message = $_.Exception.Message
            if ($session) { $message = $message.Replace([string]$session.opaque_ref, '<session>') }
            Write-Warning "Cycle $cycle failed: $message"
            if ($_.Exception.Data['XenSessionInvalid'] -or $message -match '(?i)\bSESSION_INVALID\b|session (?:has )?expired') {
                if ($session) { $session | Disconnect-XenServer -ErrorAction SilentlyContinue }
                $session = $null
                Write-Host 'Session is invalid; the next cycle will reconnect.'
            }
        }
        if ($MaxCycles -gt 0 -and $cycle -ge $MaxCycles) {
            if ($lastError) { throw $lastError }
            break
        }
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($PollSeconds)
        while ([DateTimeOffset]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $StopFile)) {
            $null = $waitHandle.Wait(1000)
        }
    }
} finally {
    try {
        if ($session) {
            $session | Disconnect-XenServer -ErrorAction SilentlyContinue
            Write-Host 'XenServer session closed.'
        }
    } finally {
        $waitHandle.Dispose()
        if ($transcribing) { $null = Stop-Transcript }
    }
}