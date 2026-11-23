<#
.SYNOPSIS
    Fleet updater for Omnissa Access Connectors. Stages the installer payload from
    a central share to each connector and runs Install-AccessConnector.ps1 on it
    remotely - PARALLEL across tenants, SEQUENTIAL within a tenant, with a health
    gate so every tenant keeps at least one connector online at all times.

.DESCRIPTION
    Reads a fleet definition (.psd1) listing tenants and their connectors. For each
    tenant it processes connectors one at a time: copy payload -> run the installer
    remotely -> confirm success/health -> only then move to the next connector. If a
    connector fails, that tenant's sequence STOPS (the untouched connectors stay
    online). Different tenants run concurrently, so the whole fleet finishes in one
    window without ever taking a tenant fully offline.

    Each connector's payload is copied to LOCAL disk on the connector first (via the
    remote session), so the installer reads local absolute paths - no share double
    hop, and it dovetails with Install-AccessConnector.ps1's own path resolution.

    Secrets (es-config, PFX, service account passwords) are collected once per tenant
    as SecureStrings and passed to the installer via its SecureString parameters, so
    nothing lands on a command line or in the fleet file.

    KERBEROS / DOUBLE HOP: when a tenant installs KerberosAuthService, the installer's
    keytab step (ktpass/setspn/machine account) must reach a domain controller from
    the connector - a second hop from the remote session. Plain Negotiate/Kerberos
    auth will NOT delegate the credential to the DC, so the keytab step fails the same
    way it would in any un-delegated remoting context. Use -Authentication CredSSP
    (delegates the credential) OR set up resource-based constrained delegation for the
    connectors. The script warns if Kerberos connectors are present without CredSSP.

    PREREQUISITES
      - Run as a domain admin (keytab generation needs it).
      - WinRM/PSRemoting enabled on every connector (Enable-PSRemoting).
      - For Kerberos connectors: CredSSP enabled client + server, or RBCD.
      - The central share reachable from THIS machine (the orchestrator).
      - Install-AccessConnector.ps1 present in the staging root.

.PARAMETER FleetConfig
    Path to the fleet .psd1 (see the example that ships alongside this script).

.PARAMETER Credential
    Domain-admin PSCredential for remoting + keytab. Prompted if omitted.

.PARAMETER Authentication
    WinRM auth. Use CredSSP for tenants that install KerberosAuthService.

.PARAMETER RemoteStageDir
    Local folder created on each connector to receive the payload.
    Default C:\ProgramData\AccessConnectorUpdate.

.PARAMETER MaxParallelTenants
    Cap on tenants updated concurrently. Default: all of them.

.PARAMETER ForceReinstall
    Pass -ForceReinstall to every install (same-version reapply = uninstall+fresh).
    Otherwise the per-tenant 'ForceReinstall' value (or the installer's version gate)
    decides.

.PARAMETER DryRun
    Run each connector's installer with -DryRun (pre-flight only, nothing changes).
    Ideal first pass to validate the whole fleet's paths/certs/creds.

.EXAMPLE
    .\Update-AccessConnectorFleet.ps1 -FleetConfig .\fleet.psd1 -DryRun
    # validate the entire fleet, no changes

.EXAMPLE
    .\Update-AccessConnectorFleet.ps1 -FleetConfig .\fleet.psd1 -Authentication CredSSP
    # real run; CredSSP so the Kerberos keytab step can reach the DC
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$FleetConfig,

    [System.Management.Automation.PSCredential]$Credential,

    [ValidateSet('Default','Negotiate','Kerberos','CredSSP')]
    [string]$Authentication = 'Negotiate',

    [string]$RemoteStageDir = 'C:\ProgramData\AccessConnectorUpdate',

    [int]$MaxParallelTenants,

    [switch]$ForceReinstall,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- load + validate fleet -----------------------------------------------

$fleet = Import-PowerShellDataFile -Path $FleetConfig
$stagingRoot   = $fleet.StagingRoot
$centralLogDir = if ($fleet.CentralLogRoot) { $fleet.CentralLogRoot } else { Join-Path (Split-Path $FleetConfig -Parent) 'FleetLogs' }
$scriptPath    = Join-Path $stagingRoot 'Install-AccessConnector.ps1'

if (-not (Test-Path -LiteralPath $stagingRoot))  { throw "StagingRoot not found: $stagingRoot" }
if (-not (Test-Path -LiteralPath $scriptPath))   { throw "Install-AccessConnector.ps1 not found in staging root: $scriptPath" }
if (-not (Test-Path -LiteralPath $centralLogDir)) { New-Item -ItemType Directory -Path $centralLogDir -Force | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runLog = Join-Path $centralLogDir "FleetUpdate_$stamp.log"
function Log { param([string]$m,[string]$lvl='INFO')
    $line = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lvl, $m
    Add-Content -Path $runLog -Value $line
    $c = switch ($lvl) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $line -ForegroundColor $c
}

Log "Fleet update starting. Config: $FleetConfig  Staging: $stagingRoot"
Log "Auth: $Authentication   DryRun: $DryRun   ForceReinstall(global): $ForceReinstall"

# validate per-tenant staging files + collect Kerberos-without-CredSSP warning
$kerbNoCredSSP = @()
foreach ($t in $fleet.Tenants) {
    foreach ($rel in @($t.Installer, $t.ConfigFile, $t.TrustStore)) {
        $p = Join-Path $stagingRoot $rel
        if (-not (Test-Path -LiteralPath $p)) { throw "Tenant '$($t.Name)': staging item not found: $p" }
    }
    foreach ($c in $t.Connectors) {
        $p = Join-Path $stagingRoot $c.Pfx
        if (-not (Test-Path -LiteralPath $p)) { throw "Tenant '$($t.Name)' / $($c.Computer): PFX not found: $p" }
    }
    if (($t.Services -match 'KerberosAuthService') -and $Authentication -ne 'CredSSP') { $kerbNoCredSSP += $t.Name }
}
if ($kerbNoCredSSP.Count -and -not $DryRun) {
    Log "Tenants install KerberosAuthService but -Authentication is not CredSSP: $($kerbNoCredSSP -join ', '). The keytab step needs to reach a DC (a second hop) and will likely fail without CredSSP or RBCD. Continue only if delegation is configured another way." 'WARN'
}

# --- credentials + per-tenant secrets ------------------------------------

if (-not $Credential) { $Credential = Get-Credential -Message 'Domain admin for remoting + keytab (DOMAIN\user)' }

$tenantSecrets = @{}
foreach ($t in $fleet.Tenants) {
    Write-Host ""
    Write-Host "Secrets for tenant '$($t.Name)':" -ForegroundColor Cyan
    $tenantSecrets[$t.Name] = @{
        Cfg = Read-Host -AsSecureString "  es-config.json password"
        Pfx = Read-Host -AsSecureString "  PFX password (shared across this tenant's connectors)"
        Svc = Read-Host -AsSecureString "  service account ($($t.ServiceAccount)) password"
    }
}

# --- per-tenant worker (self-contained; runs sequentially over connectors) --

$TenantWorker = {
    param([hashtable]$Ctx)

    $t        = $Ctx.Tenant
    $results  = New-Object System.Collections.Generic.List[object]
    $stageRel = @{ Installer=$t.Installer; Config=$t.ConfigFile; Trust=$t.TrustStore }

    foreach ($c in $t.Connectors) {
        $res = [pscustomobject]@{
            Tenant=$t.Name; Computer=$c.Computer; Status='Pending'
            ExitCode=$null; Health=''; AuditLog=''; Message=''
        }

        $session = $null
        try {
            $session = New-PSSession -ComputerName $c.Computer -Credential $Ctx.Credential -Authentication $Ctx.Authentication -ErrorAction Stop

            # fresh remote staging dir + Logs
            Invoke-Command -Session $session -ArgumentList $Ctx.RemoteStageDir -ScriptBlock {
                param($d)
                if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $d -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $d 'Logs') -Force | Out-Null
            }

            # copy payload from THIS machine -> connector local disk (no double hop)
            $pfxName = Split-Path $c.Pfx -Leaf
            Copy-Item -ToSession $session -Force -Path (Join-Path $Ctx.StagingRoot 'Install-AccessConnector.ps1') -Destination (Join-Path $Ctx.RemoteStageDir 'Install-AccessConnector.ps1')
            Copy-Item -ToSession $session -Force -Path (Join-Path $Ctx.StagingRoot $stageRel.Installer)          -Destination (Join-Path $Ctx.RemoteStageDir (Split-Path $stageRel.Installer -Leaf))
            Copy-Item -ToSession $session -Force -Path (Join-Path $Ctx.StagingRoot $stageRel.Config)             -Destination (Join-Path $Ctx.RemoteStageDir (Split-Path $stageRel.Config -Leaf))
            Copy-Item -ToSession $session -Force -Recurse -Path (Join-Path $Ctx.StagingRoot $stageRel.Trust)     -Destination (Join-Path $Ctx.RemoteStageDir 'TrustedCerts')
            Copy-Item -ToSession $session -Force -Path (Join-Path $Ctx.StagingRoot $c.Pfx)                       -Destination (Join-Path $Ctx.RemoteStageDir $pfxName)

            # run the installer on the connector against local paths
            $inv = Invoke-Command -Session $session -ScriptBlock {
                param($Stage,$Installer,$Config,$Pfx,$Services,$SvcAcct,$Syslog,$Force,$Dry,$CfgPw,$PfxPw,$SvcPw)
                Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
                $splat = @{
                    InstallerPath          = Join-Path $Stage $Installer
                    ConfigFilePath         = Join-Path $Stage $Config
                    Services               = ($Services -split ',')
                    TrustStoreCertsPath    = Join-Path $Stage 'TrustedCerts'
                    SslCertPath            = Join-Path $Stage $Pfx
                    ServiceAccount         = $SvcAcct
                    ConfigFilePassword     = $CfgPw
                    SslCertPassword        = $PfxPw
                    ServiceAccountPassword = $SvcPw
                    LogPath                = Join-Path $Stage 'Logs'
                }
                if ($Syslog) { $splat.SyslogHost     = $Syslog }
                if ($Force)  { $splat.ForceReinstall  = $true }
                if ($Dry)    { $splat.DryRun          = $true }
                & (Join-Path $Stage 'Install-AccessConnector.ps1') @splat *>&1 | Out-Null
                $code = $LASTEXITCODE
                $log  = Get-ChildItem (Join-Path $Stage 'Logs') -Filter 'AccessConnector_Audit_*.log' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                [pscustomobject]@{
                    ExitCode  = $code
                    AuditName = if ($log) { $log.Name } else { '' }
                    AuditText = if ($log) { Get-Content -Raw -LiteralPath $log.FullName } else { '' }
                }
            } -ArgumentList $Ctx.RemoteStageDir, (Split-Path $stageRel.Installer -Leaf), (Split-Path $stageRel.Config -Leaf), $pfxName, $t.Services, $t.ServiceAccount, $t.Syslog, ($Ctx.ForceReinstall -or [bool]$t.ForceReinstall), $Ctx.DryRun, $Ctx.CfgPw, $Ctx.PfxPw, $Ctx.SvcPw

            $res.ExitCode = $inv.ExitCode
            # persist the connector's audit log centrally
            if ($inv.AuditText) {
                $dest = Join-Path $Ctx.CentralLogDir ("{0}_{1}_{2}" -f $t.Name, $c.Computer, $inv.AuditName)
                Set-Content -Path $dest -Value $inv.AuditText
                $res.AuditLog = $dest
                if ($inv.AuditText -match "/eks/health returns 'true'") { $res.Health = 'eks:true' }
                elseif ($inv.AuditText -match "Keytab file is missing")  { $res.Health = 'keytab-missing' }
            }

            if ($inv.ExitCode -in 0,3010,1641) { $res.Status = 'Success' }
            else { $res.Status = 'Failed'; $res.Message = "installer exit $($inv.ExitCode)" }
        }
        catch {
            $res.Status = 'Error'; $res.Message = $_.Exception.Message
        }
        finally {
            if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
        }

        $results.Add($res)

        # HEALTH GATE: stop this tenant's sequence on any non-success (dry run never gates)
        if ($res.Status -ne 'Success' -and -not $Ctx.DryRun) {
            $res.Message += ' | tenant sequence halted - remaining connectors left untouched/online'
            break
        }
    }

    return ,$results.ToArray()
}

# --- launch: parallel across tenants, sequential within ------------------

$useThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
$cap = if ($MaxParallelTenants -gt 0) { $MaxParallelTenants } else { $fleet.Tenants.Count }
Log "Tenants: $($fleet.Tenants.Count). Cross-tenant parallelism: $(if($useThreadJob){"ThreadJob (cap $cap)"}else{'sequential (ThreadJob unavailable - Install-Module ThreadJob or use PS7 for parallel)'})"

$allResults = New-Object System.Collections.Generic.List[object]

function New-Ctx($tenant) {
    @{
        Tenant=$tenant; StagingRoot=$stagingRoot; CentralLogDir=$centralLogDir; RemoteStageDir=$RemoteStageDir
        Credential=$Credential; Authentication=$Authentication; ForceReinstall=[bool]$ForceReinstall; DryRun=[bool]$DryRun
        CfgPw=$tenantSecrets[$tenant.Name].Cfg; PfxPw=$tenantSecrets[$tenant.Name].Pfx; SvcPw=$tenantSecrets[$tenant.Name].Svc
    }
}

if ($useThreadJob) {
    $jobs = @()
    foreach ($t in $fleet.Tenants) {
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $cap) { Start-Sleep -Seconds 2 }
        Log "Tenant '$($t.Name)': starting ($($t.Connectors.Count) connector(s), sequential)."
        $jobs += Start-ThreadJob -Name $t.Name -ScriptBlock $TenantWorker -ArgumentList (New-Ctx $t)
    }
    $jobs | Wait-Job | Out-Null
    foreach ($j in $jobs) {
        $r = Receive-Job $j
        foreach ($x in $r) { $allResults.Add($x) }
        Remove-Job $j
    }
} else {
    foreach ($t in $fleet.Tenants) {
        Log "Tenant '$($t.Name)': starting ($($t.Connectors.Count) connector(s), sequential)."
        $r = & $TenantWorker (New-Ctx $t)
        foreach ($x in $r) { $allResults.Add($x) }
    }
}

# --- summary --------------------------------------------------------------

Write-Host ""
Log "==================== FLEET SUMMARY ===================="
$allResults | Sort-Object Tenant, Computer | ForEach-Object {
    $lvl = switch ($_.Status) { 'Success' {'OK'} 'Skipped' {'INFO'} default {'ERROR'} }
    Log ("{0,-16} {1,-20} {2,-8} exit={3,-5} {4} {5}" -f $_.Tenant, $_.Computer, $_.Status, $_.ExitCode, $_.Health, $_.Message) $lvl
}
$fail = @($allResults | Where-Object { $_.Status -notin 'Success','Skipped' })
$csv = Join-Path $centralLogDir "FleetUpdate_$stamp.csv"
$allResults | Export-Csv -Path $csv -NoTypeInformation
Log "Per-connector audit logs and summary CSV in: $centralLogDir"
Log ("Done. {0} succeeded, {1} failed/errored." -f @($allResults|Where-Object{$_.Status -eq 'Success'}).Count, $fail.Count) $(if($fail.Count){'WARN'}else{'OK'})

exit ([int]($fail.Count -gt 0))
