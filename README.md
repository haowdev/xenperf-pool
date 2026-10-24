# XenServer Pool Metrics Exporter

Customer evaluation collector for recorded XenServer host and VM performance
metrics. Discover pool members through the master, read each host's
`rrd_updates` endpoint, and bulk-index finite values into Elasticsearch.
This is a Windows PowerShell 7 script package, not an installed service.

## Requirements

- Windows with PowerShell 7 (`pwsh.exe`), not Windows PowerShell 5.1.
- PowerShell 7-compatible `XenServerPSModule` from the XenServer SDK, installed
  in a PowerShell module search path. The SDK is not bundled.
- HTTPS access to the pool master and every host's management address.
  RRD data is fetched directly from each host, not relayed by the master.
- A XenServer account permitted to enumerate pools/hosts and read RRD data.
  Confirm the required role against your release and local policy.
- Elasticsearch permissions to index and, if necessary, create
  `xenserver-metrics-*` indices. Authentication supports an API key or an
  unauthenticated evaluation cluster, not Elasticsearch username/password.
- A writable collector folder for checkpoints and optional transcript logs.
- Optional Grafana with the Elasticsearch data source plugin. The dashboard
  was exercised with Grafana 11.2 and an Elasticsearch 8 data source;
  other versions are not certified by this package.

Check the module in the same PowerShell 7 environment used for collection:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable XenServerPSModule
Import-Module XenServerPSModule -ErrorAction Stop
```

## Files To Share

Distribute only these files, preserving the `grafana` subfolder:

- `README.md` and `.gitignore`.
- `Export-XenPoolPerfToElastic.ps1`.
- `Run-ScheduledPoolExport.ps1`.
- `Test-PoolExport.ps1`.
- `grafana/xenserver-pool-overview.json`.

Do not distribute credentials (`*.clixml`), API keys, logs, checkpoints,
temporary files, or stop signals. Logs contain environment details. The
working folder can contain these files even when Git ignores them: do not
ZIP it wholesale. Copy only the listed sources to a clean delivery folder
and inspect the archive. Each customer creates their own credential and
starts with no state file. No sibling `xenperf` folder is required.

## First Run

Open PowerShell 7 as the Windows account that will run the collector and
change into this package's folder. All commands below assume that location.

### Save A Local Credential

```powershell
$credential = Get-Credential -Message 'XenServer collector account'
$credential | Export-Clixml -LiteralPath .\xenserver-cred.clixml
Remove-Variable credential
```

On Windows the password uses DPAPI protection: only the same account on
the same machine can decrypt it. Restrict folder access to that account
and administrators. Never share this file or a password. Recreate the
credential if the collector account or machine changes.

### Set Endpoints And Test Once

Replace these example endpoints. `PoolMaster` is a hostname/IP, not a URL.
Trust certificates matching the master and all member management addresses.

```powershell
$run = @{
    PoolMaster = 'pool-master.example.com'
    ElasticsearchUrl = 'https://elasticsearch.example.com:9200'
}
.\Run-ScheduledPoolExport.ps1 @run
```

For API-key authentication, provision `ES_API_KEY` securely in the collector's
process environment before launch. Its value is the base64-encoded
`id:api_key` form expected by Elasticsearch. Do not put secrets in source,
task arguments, screenshots, or commands captured by transcripts. Callers
using a secure store may supply `-ElasticsearchApiKey` programmatically.
Grafana needs its own separately configured read credentials.

Certificate validation is enabled by default. For an isolated lab with
self-signed certificates only, append `-SkipCertificateCheck`. This bypasses
validation for both XenServer and Elasticsearch, not just one endpoint.
Do not use it as a production default. XenServer sessions are bearer
credentials, so unverified TLS exposes credentials and data.

### Test Session Reuse And Run Continuously

```powershell
.\Run-ScheduledPoolExport.ps1 @run -Continuous -MaxCycles 2 -PollSeconds 5
.\Run-ScheduledPoolExport.ps1 @run -Continuous
```

The bounded command performs real writes. Use it before continuous operation.
The worker keeps one session in memory, reconnects after detected XenServer
session-invalid/expired or RRD-401 errors, and disconnects on normal shutdown.
Elasticsearch failures do not invalidate the XenServer session. The module
must support `Connect-XenServer -NoWarnCertificates` and host/pool
`-SessionOpaqueRef` parameters.

`PollSeconds` is the pause after a completed or failed cycle, not a fixed
wall-clock schedule. Slow cycles delay the next cycle. Credentials are loaded
once at startup; restart after rotating them. Automatic pool-master failover
is not implemented: correct `PoolMaster` and restart if the master changes.

## Parameters

| Runner Parameter | Default | Meaning |
| --- | --- | --- |
| `PoolMaster` | Required | Pool master hostname or IP. |
| `ElasticsearchUrl` | Required | Cluster URL; a reverse-proxy prefix is supported. |
| `CredentialFile` | Package-local `xenserver-cred.clixml` | Windows DPAPI credential. |
| `ElasticsearchApiKey` | `ES_API_KEY` | Optional API key from the environment. |
| `IntervalSeconds` | `60` | RRD resolution; the server controls supported intervals. |
| `StateFile` | Package-local `xenperf-pool.state.json` | Independent checkpoint per host UUID. |
| `Continuous` | Off | Collect repeatedly using one session. |
| `PollSeconds` | `60` | Pause between continuous cycles. |
| `MaxCycles` | `0` | Unlimited; a positive value bounds continuous operation. |
| `StopFile` | Package-local `xenperf-pool.stop` | Graceful stop signal for continuous mode. |
| `LogFile` | Package-local `xenperf-pool.log` | Continuous transcript; empty string disables it. |
| `SkipCertificateCheck` | Off | Lab-only certificate validation bypass. |

The low-level exporter additionally accepts `-Credential` and a caller-owned
`-Session`. Borrowed sessions are not disconnected. Prefer the runner unless
you need to manage sessions yourself.

## Stop And Restart

In another PowerShell window, from the package folder:

```powershell
New-Item -ItemType File -Path .\xenperf-pool.stop -Force
```

The worker finishes its current cycle before disconnecting. Each HTTP request
can take up to 60 seconds, with many requests per cycle. Wait for
`XenServer session closed.` in the log/console. Forced process termination
can skip cleanup and leave a server session until expiration. An existing
stop file prevents any continuous collection; one-shot mode ignores it.

```powershell
Remove-Item .\xenperf-pool.stop -ErrorAction SilentlyContinue
.\Run-ScheduledPoolExport.ps1 @run -Continuous
```

Archive logs periodically: there is no automatic rotation. Protect logs as
operational data and avoid verbose/debug transcripts in shared reports.

## Optional Windows Scheduled Task

The scripts do not create or enable tasks automatically. After a successful
bounded test, this example starts a worker under the credential's Windows
account. Run from the package folder and customize the non-secret endpoints:

```powershell
$root = (Get-Location).Path
$account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = '-NoProfile -NonInteractive -File "{0}" -PoolMaster "pool-master.example.com" -ElasticsearchUrl "https://elasticsearch.example.com:9200" -Continuous' -f (Join-Path $root 'Run-ScheduledPoolExport.ps1')
$action = New-ScheduledTaskAction -Execute (Get-Command pwsh.exe).Source -Argument $arguments -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'XenPerf-Pool-Export' -Action $action -Trigger $trigger -Principal $principal -Settings $settings
Start-ScheduledTask -TaskName 'XenPerf-Pool-Export'
```

Do not overwrite existing tasks without reviewing them. Local policy may
require administrator assistance; do not bypass it. This example requires
the user to remain logged in and the machine awake. It is not an always-on
service. For unattended service operation, have the administrator design
account permissions, secret provisioning, startup, logging, and supervision.
API keys must be available in the task's process environment, not just in
an unrelated interactive shell.

Disable the task before signaling a graceful stop:

```powershell
Disable-ScheduledTask -TaskName 'XenPerf-Pool-Export'
New-Item -ItemType File -Path .\xenperf-pool.stop -Force
Get-ScheduledTask -TaskName 'XenPerf-Pool-Export'
```

Before scheduled restart, remove the stop file, enable the task, and start
it. Do not run the old single-host exporter alongside this collector or
share its state file between workers. There is no cross-process file lock.

## Data And Reliability Limits

- Exported data comprises finite values returned by host RRD responses,
  including resident VM metrics. Disabled/unrecorded sources, stopped VM
  histories on other hosts, and unlimited historical data are not collected.
- Requests use `AVERAGE`. Missing, NaN, and infinite values are skipped.
- A fresh checkpoint starts one interval ago, not at the start of retention.
  Initial retry boundaries are saved separately for each discovered host.
- A host's checkpoint advances only after all its bulk batches succeed.
  HTTP and item-level errors fail that host's cycle; other hosts continue.
  Batches contain at most 2,000 documents. Failures retry next cycle.
- One-shot failures throw. Continuous failures log warnings and retry;
  bounded execution throws if the final cycle fails. A running task does
  not itself prove that data is arriving: monitor sample freshness.
- UTC sample dates determine `xenserver-metrics-yyyy.MM.dd` index names.
  Stable IDs include pool, collection host, object, metric, consolidation
  function, and timestamp. Retries overwrite identical IDs within this
  exporter. IDs differ from the old single-host exporter. Migrated VM
  samples can coexist under different collection-host IDs.
- Documents include `@timestamp`, numeric `value`, `xen.pool_uuid`,
  `xen.host_uuid`, `xen.host_name`, `xen.object_type`, `xen.object_uuid`,
  `xen.metric`, `xen.cf`, and `xen.ts_epoch`. VM documents also include
  `xen.object_name` and `xen.is_control_domain`; control-domain CPU and memory
  metrics are collected from each host's control-domain RRD. The exporter
  derives `dom0_memory_used_percent` from `memory`, `memory_internal_free`,
  and the XenAPI `memory_static_max`. The dashboard plots that percentage.
  Its metric explorer labels VM series with their XenServer name.
- No index templates or retention policies are installed. Provision suitable
  mappings and lifecycle rules before production. Grafana expects dates,
  numeric values, and aggregatable `.keyword` subfields for string IDs.
  Incompatible existing mappings require new indices, not an in-place fix.
- Preserve the checkpoint for incremental operation. Deleting it resets
  collection to one interval ago, not a full backfill. Long outages can
  exceed RRD retention, losing unavailable samples. Host polling is
  sequential; catch-up speed and memory depend on pool size and volume.
  Each fetched host response and its converted documents reside in memory.

## Grafana Dashboard

1. Configure an Elasticsearch data source with your cluster URL and read
   credentials. Set index pattern `xenserver-metrics-*`, time field
   `@timestamp`, minimum interval `1m`, and the correct Elasticsearch version.
2. Use Grafana's dashboard import page to upload
   `grafana/xenserver-pool-overview.json` and select that data source.
3. Open **XenServer Pool Overview** and use Host and Explorer Metric filters.
   The default time range is the last 24 hours.

The 16 panels cover observed hosts/VMs, sample count and freshness, CPU,
load, memory, domains, network, storage, power, dom0 CPU and memory, and
any recorded metric.
Counts are observations in the selected range, not current live health.
VM observations include each host's control domain. Summary panels group by
pool; the dashboard is intended for one pool's dataset. Refresh only
queries Elasticsearch; it never runs the collector.

For no data, check sample freshness, time range, filters, data-source health,
mappings, and collector logs. Import `403: origin not allowed` errors require
checking Grafana's public URL and proxy Host/protocol forwarding, without
disabling CSRF. Elasticsearch `502` errors indicate a gateway/upstream issue,
not automatically bad XenServer credentials. Diagnose `401` at its source.

## Offline Tests And Evaluation Status

```powershell
.\Test-PoolExport.ps1
```

Mocked tests contact no external services. They cover host attribution,
finite values, deterministic retries, independent checkpoints, bulk rejection,
session reuse/expiration, RRD vs Elasticsearch `401` handling, TLS defaults,
and graceful shutdown. Temporary credentials use dummy data and are removed.

Prior live evaluation exercised two pool hosts, recorded VM metrics,
session reuse, and Grafana panels. Customer XenServer versions, RBAC,
certificate trust, master failover, and large-pool performance still require
validation in the customer's environment. This is evaluation code, not
a claim of production support or certification.
