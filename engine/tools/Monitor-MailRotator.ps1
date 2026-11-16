<#
.SYNOPSIS
  Live supervisor for a MailRotator run.

.DESCRIPTION
  Watches the newest run log and prints a live dashboard: messages sent,
  failures, the current egress IP, the creative variant in use and the rate.
  Also surfaces anything that needs attention (integrity failures, a run that
  stopped, sustained errors) so an operator can intervene.

.PARAMETER IntervalSeconds
  Refresh interval. Default 5.

.PARAMETER RunStamp
  Watch a specific run (the stamp in run-<stamp>.jsonl). Defaults to the most
  recent run.

.PARAMETER Once
  Print a single snapshot and exit instead of following the log.

.EXAMPLE
  .\tools\Monitor-MailRotator.ps1 -IntervalSeconds 5
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 5,
    [string]$RunStamp = '',
    [string]$ClientId = '',
    [switch]$Once
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\Client.ps1')
$logDir = Get-ClientLogDir -ProjectRoot $root -ClientId $ClientId

function Get-ActiveRun {
    param([string]$Stamp)
    $pattern = if ($Stamp) { "run-$Stamp.jsonl" } else { 'run-*.jsonl' }
    $f = Get-ChildItem -Path $logDir -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return $f
}

function Get-Snapshot {
    param($LogFile)
    $sent = 0; $failed = 0; $skipped = 0
    $ips = @{}; $variants = @{}
    $lastError = ''
    $lastTs = ''
    $rotations = 0

    if ($LogFile) {
        foreach ($line in (Get-Content -LiteralPath $LogFile.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            try { $e = $line | ConvertFrom-Json } catch { continue }
            $lastTs = $e.ts
            if ($e.msg -like 'Rotated egress IP*') { $rotations++ }
            if ($e.msg -like 'Creative rotated*') { $rotations++ }
            if ($e.lvl -eq 'ERROR' -or $e.lvl -eq 'WARN') { $lastError = "$($e.lvl): $($e.msg)" }
        }
    }

    # counts come from the outcome records the supervisor writes alongside
    $reportFile = if ($LogFile) {
        Join-Path $logDir ("report-" + $LogFile.BaseName.Replace('run-', '') + '.json')
    }
    else { $null }
    $perIp = @(); $perVariant = @(); $totals = $null
    if ($reportFile -and (Test-Path -LiteralPath $reportFile)) {
        try {
            $rep = Get-Content -LiteralPath $reportFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $totals = $rep.totals; $perIp = @($rep.perIp); $perVariant = @($rep.perVariant)
        }
        catch { }
    }
    else {
        # report is written at the end, so fall back to counting the log
        $sent = (Select-String -Path $LogFile.FullName -Pattern '"msg":"sent ' -ErrorAction SilentlyContinue).Count
        $failed = (Select-String -Path $LogFile.FullName -Pattern '"msg":"failed ' -ErrorAction SilentlyContinue).Count
    }

    return [PSCustomObject]@{
        LogFile = if ($LogFile) { $LogFile.Name } else { '(none)' }
        Totals = $totals
        Sent = if ($totals) { $totals.sent } else { $sent }
        Failed = if ($totals) { $totals.failed } else { $failed }
        PerIp = $perIp
        PerVariant = $perVariant
        Rotations = $rotations
        LastError = $lastError
        LastTs = $lastTs
    }
}

Write-Host ''
Write-Host '  MAIL MOWAFAK  -  live supervisor' -ForegroundColor Cyan
Write-Host ''

$active = Get-ActiveRun -Stamp $RunStamp
if (-not $active) {
    Write-Host '  No run log found in logs\.' -ForegroundColor Yellow
    Write-Host '  Start a run first: .\Send-Mail.ps1' -ForegroundColor Yellow
    exit 1
}

do {
    Clear-Host
    Write-Host ''
    Write-Host '  MAIL MOWAFAK  -  live supervisor' -ForegroundColor Cyan
    Write-Host "  run: $($active.Name)   updated: $($active.LastWriteTime.ToString('HH:mm:ss'))" -ForegroundColor DarkGray
    Write-Host ''

    $s = Get-Snapshot -LogFile $active
    Write-Host ('  {0,-22} {1}' -f 'messages sent:', $s.Sent) -ForegroundColor Green
    Write-Host ('  {0,-22} {1}' -f 'failures:', $s.Failed) -ForegroundColor $(if ($s.Failed -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host ('  {0,-22} {1}' -f 'rotations (IP/creative):', $s.Rotations) -ForegroundColor Gray

    if ($s.PerIp.Count -gt 0) {
        Write-Host ''
        Write-Host '  egress IPs in use:' -ForegroundColor Gray
        foreach ($p in $s.PerIp) {
            Write-Host ("    {0,-16} sent={1,-6} failed={2,-5} total={3}" -f $p.EgressIp, $p.Sent, $p.Failed, $p.Total) -ForegroundColor DarkGray
        }
    }
    if ($s.PerVariant.Count -gt 0) {
        Write-Host ''
        Write-Host '  creative variants:' -ForegroundColor Gray
        foreach ($v in $s.PerVariant) {
            Write-Host ("    {0,-16} sent={1,-6} failed={2,-5} total={3}" -f $v.Variant, $v.Sent, $v.Failed, $v.Total) -ForegroundColor DarkGray
        }
    }
    if ($s.LastError) {
        Write-Host ''
        Write-Host "  last warning/error: $s.LastError" -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  Ctrl+C to stop watching.' -ForegroundColor DarkGray

    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSeconds
    $active = Get-ActiveRun -Stamp $RunStamp
} while ($active)
