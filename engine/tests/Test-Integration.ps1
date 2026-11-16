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
<#
  Integration test: drives Send-Mail.ps1 against the local fake SMTP server.

  Verifies the full pipeline:
    - messages are actually delivered (counted on the server)
    - the run rotates the egress IP at the batch boundary
    - the checkpoint records progress and resume skips processed recipients
    - the run report is produced
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $env:TEMP "mr_it_$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work | Out-Null

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

# ---- start fake SMTP server as a child process ----
# A background job cannot be stopped reliably here: the server blocks in an
# accept call, so Stop-Job hangs. A child process can simply be killed.
$smtpLog = Join-Path $work 'smtp.jsonl'
$serverScript = Join-Path $root 'tests\FakeSmtpServer.ps1'
$stop1 = Join-Path $work 'stop1.flag'

$serverProc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serverScript,
    '-Port', '2526', '-LogPath', $smtpLog, '-StopFilePath', $stop1) `
    -PassThru -WindowStyle Hidden

function Wait-SmtpReady([int]$Port, [int]$TimeoutSec = 20) {
    for ($i = 0; $i -lt ($TimeoutSec * 4); $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $probe = New-Object System.Net.Sockets.TcpClient
            $probe.Connect('127.0.0.1', $Port)
            $probe.Close()
            return $true
        }
        catch { }
    }
    return $false
}

if (-not (Wait-SmtpReady -Port 2526)) { throw 'Fake SMTP server did not start on port 2526.' }
Write-Host '  (fake SMTP server up on 2526)'

try {
    # start a local HTTP server so the link reachability check has a real target
    $httpLog = Join-Path $work 'http.log'
    $httpScript = Join-Path $root 'tests\FakeHttpServer.ps1'
    $httpProc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $httpScript,
        '-Port', '2528', '-LogPath', $httpLog) `
        -PassThru -WindowStyle Hidden
    $httpUp = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $probe = Invoke-WebRequest -Uri 'http://127.0.0.1:2528/ping' -UseBasicParsing -TimeoutSec 3
            if ($probe.StatusCode -eq 200) { $httpUp = $true; break }
        }
        catch { }
    }
    if (-not $httpUp) { throw 'Fake HTTP server did not start on port 2528.' }

    # ---- build a test workspace ----
    $proj = Join-Path $work 'MailRotator'
    Copy-Item -Path $root -Destination $proj -Recurse -Force
    Get-ChildItem (Join-Path $proj 'logs') -File -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    Get-ChildItem (Join-Path $proj 'state') -File -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::Delete($_.FullName) }

    # 300 recipients so we cross the 150 boundary twice
    $csv = Join-Path $proj 'data\recipients.csv'
    $lines = @('email,name,company,segment')
    for ($i = 1; $i -le 300; $i++) {
        $lines += "user$i@charter.net,User $i,Company $i,seg$($i % 3)"
    }
    $lines | Set-Content -LiteralPath $csv -Encoding UTF8

    # ---- config pointed at the fake server, proxy disabled ----
    $cfg = Get-Content (Join-Path $proj 'config\config.json') -Raw | ConvertFrom-Json
    $cfg.smtp.host = '127.0.0.1'
    $cfg.smtp.port = 2526
    $cfg.smtp.encryption = 'none'
    $cfg.smtp.username = 'tester@optonline.net'
    $cfg.smtp.passwordEnv = ''
    $cfg.smtp.password = 'testpass'
    $cfg.proxy.mode = 'none'
    $cfg.proxy.host = ''
    $cfg.proxy.port = 0
    $cfg.proxy.usernameTemplate = ''
    $cfg.proxy.passwordEnv = ''
    $cfg.proxy.password = ''
    $cfg.proxy.rotationEvery = 150
    $cfg.batch.size = 150
    $cfg.batch.delayBetweenMessagesMs = 0
    $cfg.message.fromEmail = 'tester@optonline.net'
    $cfg.message.requireUnsubscribe = $false
    $cfg.message.brandName = 'Test Brand'
    $cfg.message.landingUrl = 'http://127.0.0.1:2528/base'
    $cfg.message.unsubscribeUrl = 'http://127.0.0.1:2528/unsubscribe'
    $cfg.message.listUnsubscribe = ''
    # point each creative at its own link so link rotation is observable
    function Set-Prop($obj, [string]$name, $value) {
        if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
        else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    }
    Set-Prop $cfg.message.variants[0] 'landingUrl' 'http://127.0.0.1:2528/v1'
    Set-Prop $cfg.message.variants[0] 'shortLink' ''
    Set-Prop $cfg.message.variants[1] 'landingUrl' ''
    Set-Prop $cfg.message.variants[1] 'shortLink' 'http://127.0.0.1:2528/v2'
    $cfg | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $proj 'config\config.json') -Encoding UTF8

    Write-Host '=== RUN 1: send 300 messages in batches of 150 ===' -ForegroundColor Cyan
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'Send-Mail.ps1') `
        -ConfigPath (Join-Path $proj 'config\config.json') -RecipientsPath $csv 2>&1
    $out | Where-Object { $_ -match 'sent|failed|ROTATION|sent  ' } | Select-Object -First 3 | ForEach-Object { Write-Host "  $_" }

    # server-side count
    Start-Sleep -Seconds 1
    $delivered = @()
    if (Test-Path -LiteralPath $smtpLog) { $delivered = @(Get-Content -LiteralPath $smtpLog -Encoding UTF8 | Where-Object { $_.Trim() }) }

    Check 'server received 300 messages' ($delivered.Count -eq 300) "got: $($delivered.Count)"
    if ($delivered.Count -gt 0) {
        $rec = $delivered[0] | ConvertFrom-Json
        Check 'envelope sender is correct' ($rec.from -eq 'tester@optonline.net') "got: $($rec.from)"
        Check 'recipient preserved' ($rec.rcpt[0] -like '*@charter.net') "got: $($rec.rcpt[0])"
    }

    # ---- report ----
    $reports = @(Get-ChildItem (Join-Path $proj 'logs') -Filter 'report-*.json')
    Check 'run report produced' ($reports.Count -ge 1)
    if ($reports.Count -ge 1) {
        $rep = Get-Content $reports[0].FullName -Raw | ConvertFrom-Json
        Check 'report sent count is 300' ($rep.totals.sent -eq 300) "got: $($rep.totals.sent)"
        Check 'report batch count is 2' ($rep.totals.batches -eq 2) "got: $($rep.totals.batches)"
        Check 'rotation recorded' ($rep.totals.rotations -ge 1) "got: $($rep.totals.rotations)"
        Check 'per-IP attribution present' ($rep.perIp.Count -ge 1)
        Check 'report carries brand' ($rep.brand -eq 'Test Brand') "got: $($rep.brand)"

        # creative rotation: 2 variants over 300 messages = 150 each
        $v = @($rep.perVariant)
        Check 'two creative variants recorded' ($v.Count -eq 2) "got: $($v.Count)"
        $v1 = $v | Where-Object { $_.Variant -eq 'v1' } | Select-Object -First 1
        $v2 = $v | Where-Object { $_.Variant -eq 'v2' } | Select-Object -First 1
        Check 'variant v1 got 150 messages' ($null -ne $v1 -and $v1.Sent -eq 150) "got: $($v1.Sent)"
        Check 'variant v2 got 150 messages' ($null -ne $v2 -and $v2.Sent -eq 150) "got: $($v2.Sent)"
    }

    # ---- link rotation: each creative's own link was used ----
    $httpHits = @()
    if (Test-Path -LiteralPath $httpLog) { $httpHits = @(Get-Content -LiteralPath $httpLog -Encoding UTF8 | Where-Object { $_.Trim() }) }
    Check 'creative v1 link was used' (@($httpHits | Where-Object { $_ -match '/v1' }).Count -ge 1) "hits: $($httpHits -join ' | ')"
    Check 'creative v2 link was used' (@($httpHits | Where-Object { $_ -match '/v2' }).Count -ge 1) "hits: $($httpHits -join ' | ')"
    Check 'both creative links were checked' (
        (@($httpHits | Where-Object { $_ -match '/v1' }).Count -ge 1) -and
        (@($httpHits | Where-Object { $_ -match '/v2' }).Count -ge 1))
    # the base link is cached, so it is probed once rather than per message
    $v1Hits = @($httpHits | Where-Object { $_ -match '/v1' }).Count
    Check 'link check is cached, not per recipient' ($v1Hits -le 3) "v1 probed $v1Hits times"

    # ---- domain scoping ----
    # This run happens in an isolated copy of the project. It writes its own
    # checkpoint, and sharing one directory with the main run would overwrite
    # the 300-message checkpoint that the resume test below relies on.
    $projD = Join-Path $work 'MailRotatorScope'
    Copy-Item -Path $proj -Destination $projD -Recurse -Force
    Get-ChildItem (Join-Path $projD 'logs') -File -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    Get-ChildItem (Join-Path $projD 'state') -File -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    $mixed = Join-Path $projD 'data\mixed.csv'
    @(
        'email,name',
        'keep1@charter.net,Keep One',
        'drop1@example.com,Drop One',
        'keep2@spectrum.net,Keep Two',
        'drop2@gmail.com,Drop Two'
    ) | Set-Content -LiteralPath $mixed -Encoding UTF8
    $cfgD = Get-Content (Join-Path $projD 'config\config.json') -Raw | ConvertFrom-Json
    $cfgD.smtp.port = 2526
    $cfgD | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $projD 'config\config.json') -Encoding UTF8
    $outD = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projD 'Send-Mail.ps1') `
        -ConfigPath (Join-Path $projD 'config\config.json') -RecipientsPath $mixed 2>&1
    $d = ($outD | Out-String)
    Check 'out-of-scope recipients were skipped' ($d -match 'Skipped 2 recipient\(s\) by domain scope')
    $repD = @(Get-ChildItem (Join-Path $projD 'logs') -Filter 'report-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($repD.Count -ge 1) {
        $rd = Get-Content $repD[0].FullName -Raw | ConvertFrom-Json
        # skipped recipients are reported in their own array, not under failures
        $skippedCodes = @($rd.skipped | Where-Object { $_.code -eq 'domain-not-allowed' })
        Check 'domain filter recorded the reason' ($skippedCodes.Count -eq 2) "got: $($skippedCodes.Count)"
        Check 'in-scope recipients still sent' ($rd.totals.sent -eq 2) "got: $($rd.totals.sent)"
        Check 'domain scope counted as skipped, not failed' ($rd.totals.skipped -eq 2 -and $rd.totals.failed -eq 0) `
            "skipped=$($rd.totals.skipped) failed=$($rd.totals.failed)"
    }
    else { Check 'domain filter report produced' $false 'no report found' }

    # ---- checkpoint (captured before the later domain-scope run rewrites it) ----
    $cp = Join-Path $proj 'state\checkpoint.json'
    Check 'checkpoint written' (Test-Path -LiteralPath $cp)
    $cpSent = -1; $cpProcessed = -1
    if (Test-Path -LiteralPath $cp) {
        $cpObj = Get-Content $cp -Raw | ConvertFrom-Json
        $cpSent = $cpObj.SentCount
        $cpProcessed = @($cpObj.Processed).Count
        Check 'checkpoint records 300 sent' ($cpSent -eq 300) "got: $cpSent"
        Check 'checkpoint records 300 processed' ($cpProcessed -eq 300) "got: $cpProcessed"
    }

    # ---- resume must not resend ----
    Write-Host ''
    Write-Host '=== RUN 2: resume must send nothing new ===' -ForegroundColor Cyan
    $smtpLog2 = Join-Path $work 'smtp2.jsonl'
    $stop2 = Join-Path $work 'stop2.flag'
    $serverProc2 = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serverScript,
        '-Port', '2527', '-LogPath', $smtpLog2, '-StopFilePath', $stop2) `
        -PassThru -WindowStyle Hidden
    if (-not (Wait-SmtpReady -Port 2527)) { throw 'Second fake SMTP server did not start on port 2527.' }

    $cfg2 = Get-Content (Join-Path $proj 'config\config.json') -Raw | ConvertFrom-Json
    $cfg2.smtp.port = 2527
    $cfg2 | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $proj 'config\config.json') -Encoding UTF8

    $out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $proj 'Send-Mail.ps1') `
        -ConfigPath (Join-Path $proj 'config\config.json') -RecipientsPath $csv -Resume 2>&1
    Start-Sleep -Seconds 1
    $delivered2 = @()
    if (Test-Path -LiteralPath $smtpLog2) { $delivered2 = @(Get-Content -LiteralPath $smtpLog2 -Encoding UTF8 | Where-Object { $_.Trim() }) }
    Check 'resume sent 0 new messages' ($delivered2.Count -eq 0) "got: $($delivered2.Count)"
    # ---- white-label client run ----
    Write-Host ''
    Write-Host '=== RUN 3: a client profile drives the campaign ===' -ForegroundColor Cyan
    $clientDir = Join-Path $proj 'clients\itest'
    [void](New-Item -ItemType Directory -Path $clientDir -Force)
    $clientJson = [PSCustomObject]@{
        id   = 'itest'
        name = 'ITest Brand'
        smtp = [PSCustomObject]@{
            provider = 'auto'; host = '127.0.0.1'; port = 2527; encryption = 'none'
            username = 'tester@optonline.net'; passwordEnv = ''; password = 'testpass'
            label = 'itest-1'
        }
        message = [PSCustomObject]@{
            brandName = 'ITest Brand'; fromName = 'ITest Brand'; fromEmail = 'tester@optonline.net'
            replyTo = 'tester@optonline.net'; requireUnsubscribe = $false
            subject = 'Hi {{first_name}}, an ITest update'
            templatePath = 'message.html'
            landingUrl = 'http://127.0.0.1:2528/v1'
            physicalAddress = '1 Test St'
            allowedDomains = @('charter.net')
        }
    }
    $clientJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $clientDir 'client.json') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $proj 'config\template.html') -Destination (Join-Path $clientDir 'message.html') -Force
    $csv2 = Join-Path $proj 'data\client.csv'
    @('email,name', 'c1@charter.net,Client One', 'c2@charter.net,Client Two') | Set-Content -LiteralPath $csv2 -Encoding UTF8

    $sendArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $proj 'Send-Mail.ps1'),
        '-ClientPath', (Join-Path $clientDir 'client.json'), '-ClientId', 'itest',
        '-RecipientsPath', $csv2, '-SkipUrlChecks')
    $out3 = & powershell @sendArgs 2>&1
    $t3 = ($out3 | Out-String)
    Start-Sleep -Seconds 1
    $delivered3 = @(Get-Content -LiteralPath $smtpLog2 -Encoding UTF8 | Where-Object { $_.Trim() })
    Check 'client run delivered 2 messages' ($delivered3.Count -eq 2) "got: $($delivered3.Count)"
    Check 'client brand reaches the run' ($t3 -match 'ITest Brand')
    Check 'client keeps its own state' (Test-Path -LiteralPath (Join-Path $proj 'state\itest\checkpoint.json'))
    $rep3 = @(Get-ChildItem (Join-Path $proj 'logs\itest') -Filter 'report-*.json' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($rep3.Count -ge 1) {
        $r3 = Get-Content $rep3[0].FullName -Raw | ConvertFrom-Json
        Check 'report carries the client brand' ($r3.brand -eq 'ITest Brand') "got: $($r3.brand)"
        Check 'report carries the client id' ($r3.clientId -eq 'itest') "got: $($r3.clientId)"
    }
    else { Check 'client report produced' $false 'no report found' }

}
finally {
    # Kill the child processes; the servers block in an accept call, so a
    # graceful stop would need a connection they never get.
    foreach ($p in @($serverProc, $serverProc2, $httpProc)) {
        if ($p -and -not $p.HasExited) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

Write-Host ''
Write-Host "=== RESULT: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
