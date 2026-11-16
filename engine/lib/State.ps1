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
  Persistent state.

  Keeps a checkpoint so an interrupted run can resume exactly where it stopped,
  and maintains a suppression list of addresses that must never be contacted
  again (hard bounces, complaints, unsubscribes).
#>

function New-RunState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SuppressionPath
    )
    $state = [PSCustomObject]@{
        Path            = $Path
        SuppressionPath = $SuppressionPath
        Processed       = New-Object 'System.Collections.Generic.HashSet[string]'
        Suppressed      = New-Object 'System.Collections.Generic.HashSet[string]'
        RunId           = ''
        StartedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        SentCount       = 0
        FailedCount     = 0
        BatchIndex      = 0
        Rotations       = 0
    }
    return $state
}

function Import-RunState {
    param([Parameter(Mandatory)]$State)
    if (Test-Path -LiteralPath $State.Path) {
        try {
            $raw = Get-Content -LiteralPath $State.Path -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                foreach ($e in @($obj.Processed)) { if ($e) { [void]$State.Processed.Add([string]$e) } }
                if ($obj.RunId) { $State.RunId = [string]$obj.RunId }
                if ($obj.SentCount) { $State.SentCount = [int]$obj.SentCount }
                if ($obj.FailedCount) { $State.FailedCount = [int]$obj.FailedCount }
                if ($obj.BatchIndex) { $State.BatchIndex = [int]$obj.BatchIndex }
                if ($obj.Rotations) { $State.Rotations = [int]$obj.Rotations }
            }
        }
        catch {
            Write-Warning "Checkpoint at '$($State.Path)' could not be read; starting a fresh run. $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $State.SuppressionPath) {
        try {
            $raw = Get-Content -LiteralPath $State.SuppressionPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                foreach ($e in @($obj.Suppressed)) { if ($e) { [void]$State.Suppressed.Add([string]$e) } }
            }
        }
        catch {
            Write-Warning "Suppression list at '$($State.SuppressionPath)' could not be read; continuing with an empty list."
        }
    }
    return $State
}

function Save-RunState {
    param([Parameter(Mandatory)]$State)
    $obj = [PSCustomObject]@{
        RunId        = $State.RunId
        StartedAtUtc = $State.StartedAtUtc
        SavedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        SentCount    = $State.SentCount
        FailedCount  = $State.FailedCount
        BatchIndex   = $State.BatchIndex
        Rotations    = $State.Rotations
        Processed    = @($State.Processed)
    }
    $dir = Split-Path -Parent $State.Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $State.Path -Encoding UTF8
}

function Save-SuppressionList {
    param([Parameter(Mandatory)]$State)
    $obj = [PSCustomObject]@{ Suppressed = @($State.Suppressed) }
    $dir = Split-Path -Parent $State.SuppressionPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $obj | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $State.SuppressionPath -Encoding UTF8
}

function Add-Suppression {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Email,
        [string]$Reason = ''
    )
    $key = $Email.Trim().ToLowerInvariant()
    if ($State.Suppressed.Contains($key)) { return $false }
    [void]$State.Suppressed.Add($key)
    if ($Reason) {
        $reasonPath = "$($State.SuppressionPath).reasons"
        $map = @{}
        if (Test-Path -LiteralPath $reasonPath) {
            try { $map = Get-Content -LiteralPath $reasonPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $map = @{} }
        }
        $obj = [PSCustomObject]@{ $key = $Reason }
        ($map | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $reasonPath -Encoding UTF8
    }
    return $true
}

function Test-Suppressed {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Email
    )
    return $State.Suppressed.Contains($Email.Trim().ToLowerInvariant())
}

function Test-Processed {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Email
    )
    return $State.Processed.Contains($Email.Trim().ToLowerInvariant())
}

function Mark-Processed {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Email
    )
    $key = $Email.Trim().ToLowerInvariant()
    if (-not $State.Processed.Contains($key)) { [void]$State.Processed.Add($key) }
}
