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
$ErrorActionPreference = 'Stop'
# Works both from the development workspace and from inside the shipped package.
$projectRoot = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\Send-Mail.ps1')) {
    (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
else {
    (Resolve-Path (Join-Path $PSScriptRoot '..\MailRotator')).Path
}
$ws = Split-Path -Parent $projectRoot
$work = Join-Path $env:TEMP "mr_launcher_$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work | Out-Null

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

# ---- fake SMTP server ----
# The secret is generated at run time. A fixed literal would end up in the
# shipped source, and the leak scan below would then flag the test file
# itself instead of a real leak.
$secret = 'S' + ([guid]::NewGuid().ToString('N').Substring(0, 20))
$smtpLog = Join-Path $work 'smtp.jsonl'
$stopFile = Join-Path $work 'stop.flag'
$server = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $projectRoot 'tests\FakeSmtpServer.ps1'),
    '-Port', '2531', '-LogPath', $smtpLog, '-StopFilePath', $stopFile, '-Password', $secret) `
    -PassThru -WindowStyle Hidden

function Wait-Port([int]$Port, [int]$TimeoutSec = 20) {
    for ($i = 0; $i -lt ($TimeoutSec * 4); $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $p = New-Object System.Net.Sockets.TcpClient
            $p.Connect('127.0.0.1', $Port); $p.Close(); return $true
        } catch { }
    }
    return $false
}

try {
    if (-not (Wait-Port 2531)) { throw 'fake SMTP server did not start' }

    # ---- isolated project copy ----
    $proj = Join-Path $work 'MailRotator'
    Copy-Item -Path $projectRoot -Destination $proj -Recurse -Force
    Get-ChildItem (Join-Path $proj 'logs') -File -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    Get-ChildItem (Join-Path $proj 'state') -File -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::Delete($_.FullName) }

    $cfg = Get-Content (Join-Path $proj 'config\config.json') -Raw | ConvertFrom-Json
    $cfg.smtp.host = '127.0.0.1'
    $cfg.smtp.port = 2531
    $cfg.smtp.encryption = 'none'
    $cfg.smtp.username = 'tester@optonline.net'
    $cfg.smtp.passwordEnv = 'OPTONLINE_SMTP_PASSWORD'
    $cfg.smtp.password = ''
    $cfg.proxy.mode = 'none'
    $cfg.message.fromEmail = 'tester@optonline.net'
    $cfg.message.requireUnsubscribe = $false
    $cfg | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $proj 'config\config.json') -Encoding UTF8

    $csv = Join-Path $proj 'data\recipients.csv'
    @(
        'email,name',
        'a1@charter.net,One',
        'a2@spectrum.net,Two',
        'a3@neo.rr.com,Three'
    ) | Set-Content -LiteralPath $csv -Encoding UTF8

    # ---- run the launcher with the password piped in ----
    Write-Host '=== launcher: real run, password supplied interactively ===' -ForegroundColor Cyan
    $out = $secret | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'tools\Run-MailRotator.ps1') `
        -RecipientsPath $csv -SkipUrlChecks 2>&1
    $text = ($out | Out-String)
    $text | Select-String 'password|Password|sent|cleared' | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }

    Check 'launcher asked for the password' ($text -match 'Optimum Online \(SMTP\) password')
    Check 'launcher confirmed the cleanup'  ($text -match 'cleared from this session')
    Check 'integrity gate passed'            ($text -match 'integrity: verified')
    Check 'messages were sent'               ($text -match 'sent a1@charter\.net')
    Check 'password not echoed to the console' (-not $text.Contains($secret))

    Start-Sleep -Seconds 1
    $delivered = @()
    if (Test-Path -LiteralPath $smtpLog) { $delivered = @(Get-Content -LiteralPath $smtpLog -Encoding UTF8 | Where-Object { $_.Trim() }) }
    Check 'server received 3 messages' ($delivered.Count -eq 3) "got: $($delivered.Count)"
    if ($delivered.Count -ge 1) {
        $rec = $delivered[0] | ConvertFrom-Json
        Check 'server saw the piped password accepted' ($rec.rcpt.Count -ge 1)
    }

    # ---- the password must not be anywhere on disk ----
    $leaks = New-Object System.Collections.Generic.List[string]
    Get-ChildItem $proj -Recurse -File | Where-Object { $_.Extension -in '.ps1','.json','.html','.csv','.md','.jsonl','.txt' } | ForEach-Object {
        $t = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -and $t.Contains($secret)) { $leaks.Add($_.FullName) }
    }
    Check 'password not written to any file' ($leaks.Count -eq 0) "leaked in: $($leaks -join ', ')"

    # ---- the password must not survive in the parent session ----
    Check 'password not left in the environment' ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('OPTONLINE_SMTP_PASSWORD')))
}
finally {
    if ($server -and -not $server.HasExited) { try { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue } catch { } }
}

Write-Host ''
Write-Host "=== RESULT: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
