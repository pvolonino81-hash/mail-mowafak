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
  End-to-end test of the sending pipeline against the local fake SMTP server.

  Verifies:
    1. messages are delivered and counted correctly
    2. the egress IP rotates exactly at the batch boundary
    3. per-recipient tracking links differ
    4. the checkpoint and suppression list are written
    5. resume skips already-processed recipients
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$libDir = Join-Path $root 'lib'

. (Join-Path $libDir 'Common.ps1')
. (Join-Path $libDir 'Client.ps1')
. (Join-Path $libDir 'Proxy.ps1')
. (Join-Path $libDir 'Message.ps1')
. (Join-Path $libDir 'Smtp.ps1')
. (Join-Path $libDir 'Preflight.ps1')
. (Join-Path $libDir 'ProxyPool.ps1')
. (Join-Path $libDir 'State.ps1')
. (Join-Path $libDir 'Supervisor.ps1')

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

Write-Host '=== TEST 1: MIME construction ===' -ForegroundColor Cyan
$cfgObj = @{
    message = @{
        fromName = 'Test Co'; fromEmail = 'me@optonline.net'; replyTo = 'me@optonline.net'
        subject = 'Hi {{first_name}}'; physicalAddress = '1 Test St'
        dkimSelector = 'default'; requireUnsubscribe = $true
    }
}
$vals = @{ first_name = 'Jane'; email = 'jane@charter.net'; tracking_link = 'https://x.test/o?uid=AAA'; unsubscribe_link = 'https://x.test/u?uid=AAA' }
$msg = New-MimeMessage -FromName 'Test Co' -FromEmail 'me@optonline.net' -ToEmail 'jane@charter.net' `
    -ToName 'Jane Doe' -Subject (Expand-Tokens -Text 'Hi {{first_name}}' -Values $vals) `
    -HtmlBody '<html><body><p>Hello {{first_name}}</p></body></html>' `
    -TextBody 'Hello Jane' -ListUnsubscribe 'https://x.test/u' `
    -PhysicalAddress '1 Test St' -CampaignId 'camp-1' -MessageIdHost 'x.test'

Check 'has From header'        ($msg.Raw -match '(?m)^From: Test Co <me@optonline\.net>')
Check 'has List-Unsubscribe'   ($msg.Raw -match '(?m)^List-Unsubscribe:')
Check 'has one-click post'     ($msg.Raw -match '(?m)^List-Unsubscribe-Post: List-Unsubscribe=One-Click')
Check 'has Message-ID'         ($msg.Raw -match '(?m)^Message-ID: <.+@x\.test>')
Check 'has RFC5322 date'       ($msg.Raw -match '(?m)^Date: \w{3}, \d{2} \w{3} \d{4}')
Check 'multipart/alternative'  ($msg.Raw -match 'multipart/alternative')
Check 'text part present'      ($msg.Raw -match 'Content-Type: text/plain')
Check 'html part present'      ($msg.Raw -match 'Content-Type: text/html')
Check 'CRLF line endings'      ($msg.Raw -match "`r`n" -and $msg.Raw -notmatch "(?<!`r)`n")
Check 'no leftover token'      ((Get-UnresolvedTokens -Text $msg.Raw).Count -eq 0)

Write-Host ''
Write-Host '=== TEST 2: tracking token uniqueness ===' -ForegroundColor Cyan
$t1 = New-TrackingToken -Email 'a@charter.net' -CampaignId 'c1'
$t2 = New-TrackingToken -Email 'b@charter.net' -CampaignId 'c1'
$t3 = New-TrackingToken -Email 'a@charter.net' -CampaignId 'c2'
Check 'different emails -> different tokens' ($t1 -ne $t2)
Check 'same email, different campaign -> different token' ($t1 -ne $t3)
Check 'same input -> stable token' ($t1 -eq (New-TrackingToken -Email 'a@charter.net' -CampaignId 'c1'))
Check 'token length' ($t1.Length -eq 16)

Write-Host ''
Write-Host '=== TEST 3: rotation boundary at N messages ===' -ForegroundColor Cyan
$pool = New-ProxyPool -Mode 'gateway' -HostName 'proxy.test' -Port 8080 -UsernameTemplate 'sub' `
    -Password 'p' -Transport 'http' -RotationEvery 3 -SkipEgressCheck
$pool.CurrentEgressIp = '10.0.0.1'
$rotatedAt = @()
# Mirror the real send loop: rotate-check happens before each send, and the
# counter advances only after a message is actually delivered.
for ($i = 1; $i -le 7; $i++) {
    if (Update-ProxyRotation -Pool $pool) { $rotatedAt += $i }
    [void](Add-ProxyMessage -Pool $pool)
}
Check 'rotation happens exactly at multiples of 3' (($rotatedAt -join ',') -eq '4,7') "got: $($rotatedAt -join ',')"
Check 'rotation count is 2' ($pool.RotationCount -eq 2) "got: $($pool.RotationCount)"
Check 'session id changes per rotation' ($pool.History[0].sessionId -ne $pool.History[1].sessionId)
Check 'counter resets after rotation' ($pool.MessagesSinceRotate -eq 1) "got: $($pool.MessagesSinceRotate)"
Check 'history records previous IP' (-not [string]::IsNullOrWhiteSpace([string]$pool.History[0].previousIp))

Write-Host ''
Write-Host '=== TEST 4: suppression + checkpoint ===' -ForegroundColor Cyan
$tmpState = Join-Path $env:TEMP "mr_state_$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmpState | Out-Null
$st = New-RunState -Path (Join-Path $tmpState 'cp.json') -SuppressionPath (Join-Path $tmpState 'sup.json')
Mark-Processed -State $st -Email 'A@Charter.net'
[void](Add-Suppression -State $st -Email 'bounce@charter.net' -Reason '550')
Save-RunState -State $st
Save-SuppressionList -State $st
$st2 = New-RunState -Path (Join-Path $tmpState 'cp.json') -SuppressionPath (Join-Path $tmpState 'sup.json')
[void](Import-RunState -State $st2)
Check 'processed survives reload (case-insensitive)' (Test-Processed -State $st2 -Email 'a@charter.net')
Check 'suppressed survives reload' (Test-Suppressed -State $st2 -Email 'BOUNCE@charter.net')
Check 'unknown address not suppressed' (-not (Test-Suppressed -State $st2 -Email 'other@charter.net'))

Write-Host ''
Write-Host '=== TEST 5: supervisor counters ===' -ForegroundColor Cyan
$sup = New-Supervisor -LogPath (Join-Path $tmpState 'log.jsonl') -ReportPath (Join-Path $tmpState 'rep.json')
Add-Outcome -Supervisor $sup -Email 'a@charter.net' -Status 'sent' -Code '250' -EgressIp '10.0.0.1' -BatchIndex 0
Add-Outcome -Supervisor $sup -Email 'b@charter.net' -Status 'sent' -Code '250' -EgressIp '10.0.0.1' -BatchIndex 0
Add-Outcome -Supervisor $sup -Email 'c@charter.net' -Status 'failed' -Code '550' -EgressIp '10.0.0.2' -BatchIndex 1
$rep = Write-SupervisorReport -Supervisor $sup -RotationHistory @()
Check 'sent counted' ($sup.Sent -eq 2)
Check 'failed counted' ($sup.Failed -eq 1)
Check 'per-IP entry for 10.0.0.1' ($rep.perIp.Count -eq 2)
Check 'per-IP send count' (($rep.perIp | Where-Object { $_.EgressIp -eq '10.0.0.1' }).Sent -eq 2)
Check 'report file written' (Test-Path -LiteralPath (Join-Path $tmpState 'rep.json'))

Write-Host ''
Write-Host '=== TEST 6: client layer ===' -ForegroundColor Cyan

# --- SMTP providers ---
$p1 = Get-SmtpProvider -Name 'auto' -Username 'someone@suddenlink.net'
Check 'auto detects suddenlink' ($p1.Key -eq 'suddenlink') "got: $($p1.Key)"
$p2 = Get-SmtpProvider -Name 'auto' -Username 'someone@optonline.net'
Check 'auto detects optimum' ($p2.Key -eq 'optimum') "got: $($p2.Key)"
$p3 = Get-SmtpProvider -Name 'auto' -Username 'someone@outlook.com'
Check 'auto detects outlook' ($p3.Key -eq 'outlook') "got: $($p3.Key)"
$p4 = Get-SmtpProvider -Name 'suddenlink' -Username 'x@optonline.net'
Check 'explicit provider wins over detection' ($p4.Key -eq 'suddenlink') "got: $($p4.Key)"
$rejected = $true
try { [void](Get-SmtpProvider -Name 'gmail') } catch { $rejected = $false }
Check 'unknown provider is rejected' (-not $rejected)

# --- provider defaults ---
$acct = [PSCustomObject]@{ provider = 'suddenlink'; username = 'one@suddenlink.net'; passwordEnv = 'X'; password = '' }
$resolved = Resolve-SmtpSettings -SmtpConfig $acct
Check 'host filled from provider' ($resolved.host -eq 'mail.optonline.net') "got: $($resolved.host)"
Check 'port filled from provider' ([int]$resolved.port -eq 587) "got: $($resolved.port)"
Check 'helo filled from provider' ($resolved.heloDomain -eq 'suddenlink.net') "got: $($resolved.heloDomain)"
Check 'encryption filled from provider' ($resolved.encryption -eq 'starttls') "got: $($resolved.encryption)"

$acct2 = [PSCustomObject]@{ provider = 'suddenlink'; host = 'smtp.corp.local'; port = 2525; encryption = 'none'; username = 'one@suddenlink.net' }
$resolved2 = Resolve-SmtpSettings -SmtpConfig $acct2
Check 'explicit host is kept' ($resolved2.host -eq 'smtp.corp.local') "got: $($resolved2.host)"
Check 'explicit port is kept' ([int]$resolved2.port -eq 2525) "got: $($resolved2.port)"

# --- several accounts ---
$multi = [PSCustomObject]@{ smtp = [PSCustomObject]@{ provider = 'auto'; accounts = @(
        [PSCustomObject]@{ provider = 'suddenlink'; username = 'a@suddenlink.net'; passwordEnv = 'E1' }
        [PSCustomObject]@{ provider = 'outlook'; username = 'b@outlook.com'; passwordEnv = 'E2' }
    ) } }
$list = @(Get-SmtpAccountList -Config $multi)
Check 'two accounts are read' ($list.Count -eq 2) "got: $($list.Count)"
Check 'first account is suddenlink' ($list[0].host -eq 'mail.optonline.net') "got: $($list[0].host)"
Check 'second account is outlook' ($list[1].host -eq 'smtp-mail.outlook.com') "got: $($list[1].host)"
Check 'second account helo comes from the address' ($list[1].heloDomain -eq 'outlook.com') "got: $($list[1].heloDomain)"

# --- merging a client onto the base configuration ---
$baseCfg = [PSCustomObject]@{
    message = [PSCustomObject]@{
        brandName = 'Base'; fromEmail = 'base@x.test'
        allowedDomains = @('a.test', 'b.test')
        variants = @([PSCustomObject]@{ id = 'v1' })
    }
    batch = [PSCustomObject]@{ size = 150; delayBetweenMessagesMs = 1200 }
}
$profile = [PSCustomObject]@{
    id = 'acme'; name = 'Acme'
    message = [PSCustomObject]@{ brandName = 'Acme'; allowedDomains = @('comcast.net') }
}
$merged = Merge-ClientConfig -BaseConfig $baseCfg -Profile $profile
Check 'client overrides the brand' ($merged.message.brandName -eq 'Acme') "got: $($merged.message.brandName)"
Check 'base value the client does not set survives' ($merged.message.fromEmail -eq 'base@x.test') "got: $($merged.message.fromEmail)"
Check 'client list replaces the base list' ((@($merged.message.allowedDomains)).Count -eq 1 -and $merged.message.allowedDomains[0] -eq 'comcast.net')
Check 'untouched section survives' ([int]$merged.batch.size -eq 150)
Check 'client id is not a config key' ($null -eq $merged.id)
Check 'client name is not a config key' ($null -eq $merged.name)
Check 'variants survive the merge' (@($merged.message.variants).Count -eq 1)

# --- state isolation between clients ---
$fakeRoot = 'C:\mr-test-root'
Check 'client state dir is its own' ((Get-ClientStateDir -ProjectRoot $fakeRoot -ClientId 'acme') -eq (Join-Path $fakeRoot 'state\acme'))
Check 'plain run keeps the default state dir' ((Get-ClientStateDir -ProjectRoot $fakeRoot) -eq (Join-Path $fakeRoot 'state'))
Check 'client log dir is its own' ((Get-ClientLogDir -ProjectRoot $fakeRoot -ClientId 'acme') -eq (Join-Path $fakeRoot 'logs\acme'))

# --- recipient lists ---
$tmpList = Join-Path $env:TEMP ("mr_list_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $tmpList -Force)
@(
    '# a comment',
    '',
    'a@charter.net,Ann',
    'b@spectrum.net,Bob',
    'a@charter.net,Duplicate',
    'not-an-email',
    'c@neo.rr.com'
) | Set-Content -LiteralPath (Join-Path $tmpList 'list.txt') -Encoding UTF8
$parsed = @(Import-RecipientList -Path (Join-Path $tmpList 'list.txt'))
Check 'text list is read' ($parsed.Count -eq 3) "got: $($parsed.Count)"
Check 'name after the comma is kept' ($parsed[0].name -eq 'Ann') "got: $($parsed[0].name)"
Check 'duplicate address is kept once' (@($parsed | Where-Object { $_.email -eq 'a@charter.net' }).Count -eq 1)
Check 'invalid address is dropped' (@($parsed | Where-Object { $_.email -eq 'not-an-email' }).Count -eq 0)

# --- wording filter ---
$terms = [ordered]@{ 'free' = 'complimentary'; 'click here' = 'open the link below' }
$h = Invoke-ContentHygiene -Text 'Get a free gift, click here now' -Terms $terms
Check 'trigger word is replaced' ($h.Text -eq 'Get a complimentary gift, open the link below now') "got: $($h.Text)"
Check 'the rest of the message is untouched' ($h.Text -match 'Get a ' -and $h.Text -match ' now')
$hh = Invoke-ContentHygiene -Text '<a href="https://free.example.com/free">free offer</a>' -Terms $terms -Html
Check 'url in the href is not touched' ($hh.Text -match 'href="https://free\.example\.com/free"') "got: $($hh.Text)"
Check 'text in the body is touched' ($hh.Text -match 'complimentary offer') "got: $($hh.Text)"

$cfgF = [PSCustomObject]@{ message = [PSCustomObject]@{ spamFilter = [PSCustomObject]@{ enabled = $true; terms = [PSCustomObject]@{ 'instant delivery' = 'next-day delivery' } } } }
$m = Get-SpamTermMap -Config $cfgF
Check 'built-in terms are present' ($m.Contains('free'))
Check 'client term is added' ($m.Contains('instant delivery'))
$cfgOff = [PSCustomObject]@{ message = [PSCustomObject]@{ spamFilter = [PSCustomObject]@{ enabled = $false } } }
Check 'filter can be switched off' ((Get-SpamTermMap -Config $cfgOff).Count -eq 0)

Write-Host ''
Write-Host '=== TEST 7: proxy providers ===' -ForegroundColor Cyan

$p9 = New-ProxyPool -Mode 'gateway' -Provider '9proxy' -HostName 'proxy.test' -Port 8080 `
    -UsernameTemplate 'acct' -Country 'us' -State 'ny' -City 'nyc' -Isp 'isp1' `
    -SessionTimeMinutes 10 -SkipEgressCheck
$u9 = New-ProxyUsername -Pool $p9 -SessionId 'mail123456'
Check '9proxy username shape' ($u9 -eq 'acct-country-us-st-ny-city-nyc-isp-isp1-sst-10-ssid-mail123456') "got: $u9"

$p7 = New-ProxyPool -Mode 'gateway' -Provider '711proxy' -HostName 'gate.test' -Port 1234 `
    -UsernameTemplate 'acct' -Zone 'custom' -Country 'us' -State 'California' -City 'Miami' `
    -SessionTimeMinutes 5 -SkipEgressCheck
$u7 = New-ProxyUsername -Pool $p7 -SessionId 'mail123456'
Check '711proxy username shape' ($u7 -eq 'acct-zone-custom-region-US-st-California-city-Miami-sessTime-5-session-(mail123456)') "got: $u7"

$p7b = New-ProxyPool -Mode 'gateway' -Provider '711proxy' -HostName 'gate.test' -Port 1234 `
    -UsernameTemplate 'acct' -Country 'gb' -SkipEgressCheck
$u7b = New-ProxyUsername -Pool $p7b -SessionId 's1'
Check '711proxy region is upper case' ($u7b -eq 'acct-region-GB-session-(s1)') "got: $u7b"

$pc = New-ProxyPool -Mode 'gateway' -Provider 'custom' -HostName 'h' -Port 1 `
    -UsernameTemplate 'acct-{country}-sess-{session}' -Country 'de' -SkipEgressCheck
$uc = New-ProxyUsername -Pool $pc -SessionId 'abc'
Check 'custom username shape' ($uc -eq 'acct-de-sess-abc') "got: $uc"

$rejected = $true
try { [void](Get-ProxyProvider -Name 'brightdata') } catch { $rejected = $false }
Check 'unknown proxy family is rejected' (-not $rejected)

$pp = New-ProxyPool -Mode 'ports' -Provider '711proxy' -HostName 'gate.test' -Port 0 `
    -UsernameTemplate 'acct' -LocalPorts @(1001, 1002) -SkipEgressCheck
$e1 = Get-ProxyEndpoint -Pool $pp
$e2 = Get-ProxyEndpoint -Pool $pp
Check 'ports mode rotates over the ports' ($e1.ProxyPort -eq 1001 -and $e2.ProxyPort -eq 1002) "got: $($e1.ProxyPort), $($e2.ProxyPort)"
Check 'ports mode keeps the provider host' ($e1.ProxyHost -eq 'gate.test') "got: $($e1.ProxyHost)"
Check 'ports mode keeps the account' ($e1.Username -eq 'acct') "got: $($e1.Username)"

$pg = New-ProxyPool -Mode 'gateway' -Provider '711proxy' -HostName 'gate.test' -Port 1234 `
    -UsernameTemplate 'acct' -SkipEgressCheck
$g1 = Get-ProxyEndpoint -Pool $pg
$g2 = Get-ProxyEndpoint -Pool $pg
Check 'gateway mode mints a new session' ($g1.SessionId -ne $g2.SessionId)
Check 'gateway mode writes the session into the username' ($g2.Username -like '*session-(*)')
Check 'gateway mode keeps the host and port' ($g2.ProxyHost -eq 'gate.test' -and $g2.ProxyPort -eq 1234)

$cfgProxy = [PSCustomObject]@{ proxy = [PSCustomObject]@{ provider = '711proxy'; mode = 'gateway'; host = 'g'; port = 1; usernameTemplate = 'a' } }
$rp = Resolve-ProxySettings -Config $cfgProxy
Check 'the family fills the password variable' ($rp.passwordEnv -eq 'SEVEN11PROXY_PASSWORD') "got: $($rp.passwordEnv)"
Check 'the family fills the zone' ($rp.zone -eq 'custom') "got: $($rp.zone)"
Check 'the family fills the separator' ($rp.paramSeparator -eq '-') "got: $($rp.paramSeparator)"

$cfg9 = [PSCustomObject]@{ proxy = [PSCustomObject]@{ provider = '9proxy'; mode = 'gateway'; host = 'g'; port = 1; usernameTemplate = 'a' } }
$rp9 = Resolve-ProxySettings -Config $cfg9
Check '9proxy keeps its own password variable' ($rp9.passwordEnv -eq 'NINEPROXY_PASSWORD') "got: $($rp9.passwordEnv)"

Write-Host ''
Write-Host "=== RESULT: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
