# ==============================================================================
#   MAILROTATOR_BANNER_START
#   MOWAFAK STORE  -  Proprietary Software
#   Product : MAIL MOWAFAK - SMTP bulk sender with rotating egress IPs
#   Copyright (c) 2026 Mowafak Store. All rights reserved.
#   Licensed to: Mowafak Store
#   ------------------------------------------------------------------------------
#   INTEGRITY PROTECTED. This file is covered by a signed manifest
#   (RSA-2048 / SHA-256). Editing it, removing this header, or
#   altering any protected file makes MAIL MOWAFAK refuse to run.
#   The private signing key is NOT distributed with this package.
#   MAILROTATOR_BANNER_END
# ==============================================================================
Set-StrictMode -Version 1.0

<#
  Supervisor.

  Tracks per-IP send counters, per-recipient outcomes and the reasons behind
  every failure, then renders a run report. This is what makes a run
  auditable rather than a black box.
#>

function New-Supervisor {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$ReportPath
    )
    $sup = [PSCustomObject]@{
        LogPath        = $LogPath
        ReportPath     = $ReportPath
        RunId          = (New-SessionId -Length 10)
        StartedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        PerIp          = @{}
        PerVariant     = @{}
        Outcomes       = New-Object System.Collections.Generic.List[object]
        Batches        = New-Object System.Collections.Generic.List[object]
        Sent           = 0
        Failed         = 0
        Skipped        = 0
                }
    return $sup
}

function Add-Outcome {
    param(
        [Parameter(Mandatory)]$Supervisor,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][ValidateSet('sent', 'failed', 'skipped')][string]$Status,
        [string]$Code = '',
        [string]$Message = '',
        [string]$EgressIp = '',
        [int]$BatchIndex = 0,
        [string]$Variant = ''
    )
    [void]$Supervisor.Outcomes.Add([PSCustomObject]@{
        ts        = (Get-Date).ToUniversalTime().ToString('o')
        email     = $Email
        status    = $Status
        code      = $Code
        message   = $Message
        egressIp  = $EgressIp
        batch     = $BatchIndex
        variant   = $Variant
    })

    switch ($Status) {
        'sent' { $Supervisor.Sent++ }
        'failed' { $Supervisor.Failed++ }
        'skipped' { $Supervisor.Skipped++ }
    }

    if (-not [string]::IsNullOrWhiteSpace($EgressIp)) {
        if (-not $Supervisor.PerIp.ContainsKey($EgressIp)) {
            $Supervisor.PerIp[$EgressIp] = [PSCustomObject]@{
                EgressIp = $EgressIp
                Sent = 0
                Failed = 0
                Total = 0
            }
        }
        $Supervisor.PerIp[$EgressIp].Total++
        if ($Status -eq 'sent') { $Supervisor.PerIp[$EgressIp].Sent++ }
        elseif ($Status -eq 'failed') { $Supervisor.PerIp[$EgressIp].Failed++ }
    }

    # per-creative counters, so each variant can be compared
    $vKey = if ([string]::IsNullOrWhiteSpace($Variant)) { '(none)' } else { $Variant }
    if (-not $Supervisor.PerVariant.ContainsKey($vKey)) {
        $Supervisor.PerVariant[$vKey] = [PSCustomObject]@{
            Variant = $vKey
            Sent = 0
            Failed = 0
            Skipped = 0
            Total = 0
        }
    }
    $Supervisor.PerVariant[$vKey].Total++
    if ($Status -eq 'sent') { $Supervisor.PerVariant[$vKey].Sent++ }
    elseif ($Status -eq 'failed') { $Supervisor.PerVariant[$vKey].Failed++ }
    else { $Supervisor.PerVariant[$vKey].Skipped++ }
}

function Add-BatchRecord {
    param(
        [Parameter(Mandatory)]$Supervisor,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$EgressIp,
        [Parameter(Mandatory)][string]$EndpointLabel,
        [int]$Sent = 0,
        [int]$Failed = 0,
        [string]$PreflightSummary = ''
    )
    [void]$Supervisor.Batches.Add([PSCustomObject]@{
        batchIndex  = $Index
        egressIp    = $EgressIp
        endpoint    = $EndpointLabel
        sent        = $Sent
        failed      = $Failed
        preflight   = $PreflightSummary
        startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
}

function Write-SupervisorReport {
    param(
        [Parameter(Mandatory)]$Supervisor,
        [Parameter(Mandatory)]$RotationHistory,
    [string]$Brand = 'MailRotator',
    [hashtable]$Meta = @{}
    )

    $perIpArray = @($Supervisor.PerIp.Values | Sort-Object -Property Total -Descending)

    $report = [PSCustomObject]@{
        brand       = $Brand
        product     = 'MailRotator'
        runId       = $Supervisor.RunId
        startedAtUtc = $Supervisor.StartedAtUtc
        finishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        totals       = [PSCustomObject]@{
            sent    = $Supervisor.Sent
            failed  = $Supervisor.Failed
            skipped = $Supervisor.Skipped
            batches = $Supervisor.Batches.Count
            rotations = $RotationHistory.Count
        }
        perIp        = $perIpArray
        perVariant   = @($Supervisor.PerVariant.Values | Sort-Object -Property Total -Descending)
        rotations    = $RotationHistory
        batches      = $Supervisor.Batches.ToArray()
        failures     = @($Supervisor.Outcomes | Where-Object { $_.status -eq 'failed' })
        skipped      = @($Supervisor.Outcomes | Where-Object { $_.status -eq 'skipped' })
    }
        foreach ($k in $Meta.Keys) {
            $report | Add-Member -NotePropertyName $k -NotePropertyValue $Meta[$k] -Force
        }

    $dir = Split-Path -Parent $Supervisor.ReportPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Supervisor.ReportPath -Encoding UTF8

    return $report
}

function Format-SupervisorReport {
    param([Parameter(Mandatory)]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('=' * 62)
    [void]$lines.Add("RUN REPORT  $($Report.runId)")
    [void]$lines.Add('=' * 62)
    [void]$lines.Add("started   : $($Report.startedAtUtc)")
    [void]$lines.Add("finished  : $($Report.finishedAtUtc)")
    [void]$lines.Add("sent      : $($Report.totals.sent)")
    [void]$lines.Add("failed    : $($Report.totals.failed)")
    [void]$lines.Add("skipped   : $($Report.totals.skipped)")
    [void]$lines.Add("batches   : $($Report.totals.batches)")
    [void]$lines.Add("rotations : $($Report.totals.rotations)")
    [void]$lines.Add('')
    [void]$lines.Add('per egress IP:')
    if ($Report.perIp.Count -eq 0) {
        [void]$lines.Add('  (none recorded)')
    }
    else {
        foreach ($p in $Report.perIp) {
            [void]$lines.Add(("  {0,-16} sent={1,-5} failed={2,-4} total={3}" -f $p.EgressIp, $p.Sent, $p.Failed, $p.Total))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('per creative variant:')
    if ($Report.perVariant.Count -eq 0) {
        [void]$lines.Add('  (none recorded)')
    }
    else {
        foreach ($v in $Report.perVariant) {
            [void]$lines.Add(("  {0,-14} sent={1,-5} failed={2,-4} skipped={3,-4} total={4}" -f $v.Variant, $v.Sent, $v.Failed, $v.Skipped, $v.Total))
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('rotation history:')
    foreach ($r in $Report.rotations) {
        [void]$lines.Add(("  #{0,-3} {1,-16} {2}  prev={3}" -f $r.rotationIndex, $r.egressIp, $r.sessionId, $r.previousIp))
    }
    if ($Report.failures.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('failures (first 25):')
        $i = 0
        foreach ($f in $Report.failures) {
            if ($i -ge 25) { break }
            [void]$lines.Add(("  {0,-34} [{1}] {2}" -f $f.email, $f.code, $f.message))
            $i++
        }
    }
    [void]$lines.Add('=' * 62)
    return ($lines -join "`n")
}
