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

function Get-ConfigValue {
    param($Object, [string]$Path, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $cur = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($part)) { return $Default }
            $cur = $cur[$part]
        }
        else {
            $p = $cur.PSObject.Properties[$part]
            if ($null -eq $p) { return $Default }
            $cur = $p.Value
        }
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

function ConvertTo-Base64 {
    param([Parameter(Mandatory)][string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-Base64 {
    param([Parameter(Mandatory)][string]$Base64)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][string]$Text)
    $b = (ConvertTo-Base64 $Text).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return $b
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function New-SessionId {
    param([int]$Length = 12)
    $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $sb = New-Object System.Text.StringBuilder
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)
        for ($i = 0; $i -lt $Length; $i++) {
            [void]$sb.Append($chars[$bytes[$i] % $chars.Length])
        }
    }
    finally { $rng.Dispose() }
    return $sb.ToString()
}

function Write-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data = @{}
    )
    $record = [ordered]@{
        ts = (Get-Date).ToUniversalTime().ToString('o')
        lvl = $Level
        msg = $Message
    }
    if ($Data -and $Data.Count -gt 0) { $record['data'] = $Data }
    $line = ($record | ConvertTo-Json -Depth 6 -Compress)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
    catch {
        Write-Warning "Cannot write log file '$Path': $($_.Exception.Message)"
    }
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function New-LineReader {
    <#
      Buffered line reader over any Stream (NetworkStream / SslStream).
      Exposes Buf/Fill/Pos so callers can assert no buffered bytes remain
      before a protocol upgrade (required around SMTP STARTTLS).
    #>
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)

    $o = [PSCustomObject]@{
        Stream = $Stream
        Buf    = New-Object byte[] 16384
        Fill   = 0
        Pos    = 0
    }

    Add-Member -InputObject $o -MemberType ScriptMethod -Name ReadLine -Value {
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            if ($this.Pos -ge $this.Fill) {
                $this.Fill = $this.Stream.Read($this.Buf, 0, $this.Buf.Length)
                $this.Pos = 0
                if ($this.Fill -le 0) { throw 'Connection closed by peer.' }
            }
            $b = $this.Buf[$this.Pos]
            $this.Pos++
            if ($b -eq 10) { return $sb.ToString() }      # LF
            if ($b -eq 13) { continue }                    # CR
            [void]$sb.Append([char]$b)
        }
    }

    Add-Member -InputObject $o -MemberType ScriptMethod -Name PendingBytes -Value {
        return ($this.Fill - $this.Pos)
    }

    return $o
}

function ConvertTo-CrlfText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    return ($t -replace "`n", "`r`n")
}
