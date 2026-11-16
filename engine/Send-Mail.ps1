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
.SYNOPSIS
  MAIL MOWAFAK - automated bulk sending over SMTP with rotating egress IPs.

.DESCRIPTION
  Sends a campaign in batches (default 150 messages). Before each batch the
  message is validated; when the batch quota is reached the egress IP is
  rotated and the next batch continues. A checkpoint lets an interrupted run
  resume, and a suppression list prevents contacting bounced or unsubscribed
  addresses again.

  The engine is white label. Everything that a recipient could possibly see
  - the brand, the sender name, the mailbox, the message, the links and the
  physical address - comes from the client profile, never from this file.
  The name of the mailer itself appears only on the operator's screen and in
  the program files; it never reaches a message.

  Several SMTP accounts may be configured. The engine opens a session on the
  first account, moves to the next one when an account stops accepting mail,
  and rotates accounts at every batch boundary.

.PARAMETER ConfigPath
  Path to the JSON configuration file.

.PARAMETER ClientId
  Id of a client profile. The profile is looked up in clients/<id>/client.json
  or clients/<id>.json. The client decides the brand, the sender, the message,
  the audience and the SMTP account.

.PARAMETER ClientPath
  Path to a client profile file. Overrides -ClientId.

.PARAMETER StateDir
  Directory for the checkpoint and the suppression list. Defaults to
  state/<client>, so two clients never share a suppression list.

.PARAMETER RecipientsPath
  Recipients. A CSV keeps every column, so extra columns work as
  {{placeholders}}. A plain text file holds one address per line, optionally
  followed by a comma and a name.

.PARAMETER DryRun
  Validate and render everything but send nothing. Writes a preview message
  and a JSON plan so the run can be inspected before going live.

.PARAMETER MaxMessages
  Optional hard cap on messages sent in this invocation.

.PARAMETER BatchSize
  Messages per batch before the IP rotates. Overrides the config value.

.PARAMETER Resume
  Continue from the saved checkpoint instead of starting fresh.

.PARAMETER SkipUrlChecks
  Skip the live reachability check of links during preflight.

.EXAMPLE
  .\Send-Mail.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt -DryRun
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$ClientId = '',
    [string]$ClientPath = '',
    [string]$StateDir = '',
    [string]$RecipientsPath = '',
    [switch]$DryRun,
    [int]$MaxMessages = 0,
    [int]$BatchSize = 0,
    [switch]$Resume,
    [switch]$SkipUrlChecks,
    [switch]$RotateBeforeFirstBatch
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated while param() defaults are evaluated in
# Windows PowerShell 5.1, so the defaults are resolved here instead.
$projectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $projectRoot 'config\config.json'
}
if ([string]::IsNullOrWhiteSpace($RecipientsPath)) {
    $RecipientsPath = Join-Path $projectRoot 'data\recipients.csv'
}

$libDir = Join-Path $projectRoot 'lib'

# --- integrity gate -------------------------------------------------------
# The protection scheme is verified before anything else runs. A modified or
# missing protected file stops the program here.
. (Join-Path $libDir 'Integrity.ps1')
$integrity = Test-MailRotatorIntegrity -ProjectRoot $projectRoot
if (-not $integrity.Passed) {
    Write-Host ''
    Write-Host '  MAIL MOWAFAK - INTEGRITY CHECK FAILED' -ForegroundColor Red
    Write-Host '  This build has been altered and will not run.' -ForegroundColor Red
    foreach ($f in $integrity.Failures) { Write-Host "    - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Restore the original files, or re-sign with tools\Protect-MailRotator.ps1' -ForegroundColor Yellow
    Write-Host '  using the private key that was supplied with this build.' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}

# The library files are dot-sourced in dependency order rather than imported as
# modules. Import-Module with -Force unloads sibling modules and drops their
# exported functions from the caller's scope, which breaks cross-module calls.
. (Join-Path $libDir 'Common.ps1')
. (Join-Path $libDir 'Client.ps1')
. (Join-Path $libDir 'Proxy.ps1')
. (Join-Path $libDir 'Message.ps1')
. (Join-Path $libDir 'Smtp.ps1')
. (Join-Path $libDir 'Preflight.ps1')
. (Join-Path $libDir 'ProxyPool.ps1')
. (Join-Path $libDir 'State.ps1')
. (Join-Path $libDir 'Supervisor.ps1')

# ---------------------------------------------------------------- config ---
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# --------------------------------------------------------------- client ----
# The client profile is applied on top of the base configuration. It carries
# the brand, the sender, the message, the audience and the SMTP account.
$clientProfile = $null
$clientKey = ''
$resolvedClientPath = Resolve-ClientProfilePath -ProjectRoot $projectRoot -ClientId $ClientId -ClientPath $ClientPath
if ($resolvedClientPath) {
    $clientProfile = Get-ClientProfile -Path $resolvedClientPath
    $config = Merge-ClientConfig -BaseConfig $config -Profile $clientProfile.Data
    Resolve-ClientPaths -Config $config -ClientDir $clientProfile.Directory -ProjectRoot $projectRoot
    # A client that brings its own message does not inherit the creatives
    # of the base configuration: its own template is the whole message.
    $clientMessage = Get-ConfigValue -Object $clientProfile.Data -Path 'message'
    $clientHasTemplate = -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Object $clientMessage -Path 'templatePath' -Default ''))
    $clientHasVariants = (@(Get-ConfigValue -Object $clientMessage -Path 'variants' -Default @())).Count -gt 0
    if ($clientHasTemplate -and -not $clientHasVariants) {
        [void](Set-ConfigValue -Object $config -Path 'message.variants' -Value @())
    }
    $clientKey = Get-SafeClientKey -Value $ClientId
    if ([string]::IsNullOrWhiteSpace($clientKey)) { $clientKey = Get-SafeClientKey -Value $clientProfile.Id }
    if ([string]::IsNullOrWhiteSpace($clientKey)) { $clientKey = Get-SafeClientKey -Value $clientProfile.Name }
    if ([string]::IsNullOrWhiteSpace($clientKey)) { $clientKey = 'client' }
}

$smtpCfg   = $config.smtp
$msgCfg    = $config.message
$proxyCfg  = Resolve-ProxySettings -Config $config
if ($null -eq $proxyCfg) { $proxyCfg = $config.proxy }
$batchCfg  = $config.batch

$effectiveBatchSize = if ($BatchSize -gt 0) { $BatchSize } else { [int]$batchCfg.size }
if ($effectiveBatchSize -le 0) { throw 'Batch size must be greater than zero.' }

# The brand a recipient sees. It comes from the client, never from the tool.
$brandLabel = [string](Get-ConfigValue -Object $msgCfg -Path 'brandName' -Default '')
if ([string]::IsNullOrWhiteSpace($brandLabel)) { $brandLabel = [string]$msgCfg.fromName }
if ([string]::IsNullOrWhiteSpace($brandLabel)) { $brandLabel = 'MAIL MOWAFAK' }

# ---------------------------------------------------------------- secrets --
# Secrets are resolved lazily so a dry run never needs credentials.
$script:smtpPasswords = @{}
$proxyPassword = $null

function Get-SmtpPassword {
    param([Parameter(Mandatory)]$Account)
    $key = [string]$Account.username
    if ($script:smtpPasswords.ContainsKey($key)) { return $script:smtpPasswords[$key] }
    $v = if ($Account.passwordEnv) {
        $secret = [Environment]::GetEnvironmentVariable([string]$Account.passwordEnv)
        if ([string]::IsNullOrWhiteSpace($secret)) {
            throw "Environment variable '$($Account.passwordEnv)' is not set. It must contain the SMTP password."
        }
        $secret
    }
    else { [string]$Account.password }
    $script:smtpPasswords[$key] = $v
    return $v
}

function Get-ProxyPassword {
    if ($null -ne $script:proxyPassword) { return $script:proxyPassword }
    $v = if ($proxyCfg.passwordEnv) {
        # Not an error yet: a dry run never opens a tunnel. The connection
        # layer rejects empty credentials when it actually needs to authenticate.
        $secret = [Environment]::GetEnvironmentVariable([string]$proxyCfg.passwordEnv)
        if ([string]::IsNullOrWhiteSpace($secret)) { '' } else { $secret }
    }
    else { [string]$proxyCfg.password }
    $script:proxyPassword = $v
    return $v
}

# ---------------------------------------------------------------- paths ----
# Relative paths inside the config are resolved against the project root
# (the directory holding this script), never against the current directory.
function Resolve-ProjectPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $projectRoot $Path)
}

$stateDir   = Get-ClientStateDir -ProjectRoot $projectRoot -ClientId $clientKey -StateDir $StateDir
$logDir     = Get-ClientLogDir  -ProjectRoot $projectRoot -ClientId $clientKey
[void](New-DirectoryIfMissing $stateDir)
[void](New-DirectoryIfMissing $logDir)

$runStamp   = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$logPath    = Join-Path $logDir "run-$runStamp.jsonl"
$reportPath = Join-Path $logDir "report-$runStamp.json"

$supervisor = New-Supervisor -LogPath $logPath -ReportPath $reportPath
Write-Host ''
Write-Host '  MAIL MOWAFAK  -  bulk sender with rotating egress IPs' -ForegroundColor Cyan
if ($clientKey) { Write-Host "  client  : $clientKey  ($brandLabel)" -ForegroundColor Cyan }
Write-Host "  integrity: verified ($($integrity.Checked) protected files)" -ForegroundColor DarkGray
Write-Host ''

$state = New-RunState -Path (Join-Path $stateDir 'checkpoint.json') -SuppressionPath (Join-Path $stateDir 'suppressed.json')
if ($Resume) {
    [void](Import-RunState -State $state)
    Write-RunLog -Path $logPath -Level 'INFO' -Message "Resuming run: $($state.SentCount) already sent, $($state.Processed.Count) processed."
}
else {
    $state.RunId = $supervisor.RunId
}

# ------------------------------------------------------------ recipients ---
if (-not (Test-Path -LiteralPath $RecipientsPath)) {
    throw "Recipients file not found: $RecipientsPath"
}
$rows = @(Import-RecipientList -Path $RecipientsPath)
if ($rows.Count -eq 0) { throw "Recipients file '$RecipientsPath' contains no usable addresses." }

Write-RunLog -Path $logPath -Level 'INFO' -Message "Loaded $($rows.Count) recipient rows from $RecipientsPath."

$templateHtml = Get-Content -LiteralPath (Resolve-ProjectPath ([string]$msgCfg.templatePath)) -Raw -Encoding UTF8
$templateText = if ($msgCfg.textTemplatePath) {
    Get-Content -LiteralPath (Resolve-ProjectPath ([string]$msgCfg.textTemplatePath)) -Raw -Encoding UTF8
}
else { $null }

$campaignId = [string]$msgCfg.campaignId
if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "camp-" + (New-SessionId -Length 8) }

# ------------------------------------------------------------ link service --
# When a link service is configured, the link that goes into the message is a
# short code on the operator's own host. The code resolves to the target of
# the creative, so the operator can move the target without touching the
# message that is already on the wire.
$linkService = Get-ConfigValue -Object $msgCfg -Path 'linkService'
$linkServiceEnabled = [bool](Get-ConfigValue -Object $linkService -Path 'enabled' -Default $false)
$linkServiceBase = [string](Get-ConfigValue -Object $linkService -Path 'baseUrl' -Default '')
$linkCodes = @{}

# ------------------------------------------------------- message variants --
# A variant is a complete, pre-approved creative: its own subject, body
# template and link. Variants rotate every 'message.rotateEvery' messages, so
# a long campaign never sends one identical body to everybody.
$variantDefs = @()
$variantList = @(Get-ConfigValue -Object $msgCfg -Path 'variants' -Default @())
if ($variantList.Count -gt 0) {
    foreach ($v in $variantList) {
        $vHtmlPath = [string](Get-ConfigValue -Object $v -Path 'templatePath' -Default '')
        $vTextPath = [string](Get-ConfigValue -Object $v -Path 'textTemplatePath' -Default '')
        $short = [string](Get-ConfigValue -Object $v -Path 'shortLink' -Default '')
        $landing = [string](Get-ConfigValue -Object $v -Path 'landingUrl' -Default ([string]$msgCfg.landingUrl))
        $variantId = [string](Get-ConfigValue -Object $v -Path 'id' -Default ("v{0}" -f ($variantDefs.Count + 1)))
        $linkBase = if ($short) { $short } else { $landing }
        if ($linkServiceEnabled -and -not [string]::IsNullOrWhiteSpace($linkServiceBase) -and -not [string]::IsNullOrWhiteSpace($landing)) {
            $code = Get-ShortLinkCode -Seed ("$clientKey|$variantId|$landing") -Length 7
            $linkBase = ($linkServiceBase.TrimEnd('/')) + '/s/' + $code
            $linkCodes[$code] = [PSCustomObject]@{
                target  = $landing
                variant = $variantId
                client  = $clientKey
            }
        }
        $variantDefs += [PSCustomObject]@{
            Id         = $variantId
            Subject    = [string](Get-ConfigValue -Object $v -Path 'subject' -Default ([string]$msgCfg.subject))
            Html       = if ($vHtmlPath) { Get-Content -LiteralPath (Resolve-ProjectPath $vHtmlPath) -Raw -Encoding UTF8 } else { $templateHtml }
            Text       = if ($vTextPath) { Get-Content -LiteralPath (Resolve-ProjectPath $vTextPath) -Raw -Encoding UTF8 } else { $null }
            LinkBase   = $linkBase
            ShortLink  = $short
        }
    }
}
else {
    $defaultLink = [string]$msgCfg.landingUrl
    if ($linkServiceEnabled -and -not [string]::IsNullOrWhiteSpace($linkServiceBase) -and -not [string]::IsNullOrWhiteSpace($defaultLink)) {
        $code = Get-ShortLinkCode -Seed ("$clientKey|default|$defaultLink") -Length 7
        $defaultLink = ($linkServiceBase.TrimEnd('/')) + '/s/' + $code
        $linkCodes[$code] = [PSCustomObject]@{ target = [string]$msgCfg.landingUrl; variant = 'default'; client = $clientKey }
    }
    $variantDefs = @([PSCustomObject]@{
        Id        = 'default'
        Subject   = [string]$msgCfg.subject
        Html      = $templateHtml
        Text      = $templateText
        LinkBase  = $defaultLink
        ShortLink = ''
    })
}

# The short-link map is written next to the project so it can be published
# with the redirect page. It holds no recipient data, only the codes.
if ($linkCodes.Count -gt 0) {
    $linksPath = Join-Path $projectRoot 'links.json'
    $map = [ordered]@{}
    foreach ($code in ($linkCodes.Keys | Sort-Object)) {
        $map[$code] = $linkCodes[$code]
    }
    $json = $map | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($linksPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-RunLog -Path $logPath -Level 'INFO' -Message "Short links: $($linkCodes.Count) code(s) written to links.json."
}

$creativeRotateEvery = [int](Get-ConfigValue -Object $msgCfg -Path 'rotateEvery' -Default 150)
if ($creativeRotateEvery -le 0) { $creativeRotateEvery = 150 }
$creativeBlock = 0
$creativeCounter = 0

Write-RunLog -Path $logPath -Level 'INFO' -Message "Loaded $($variantDefs.Count) creative variant(s); rotating every $creativeRotateEvery messages."
$proxyProvider = [string](Get-ConfigValue -Object $proxyCfg -Path 'provider' -Default '9proxy')
Write-RunLog -Path $logPath -Level 'INFO' -Message "Proxy: $proxyProvider in $([string]$proxyCfg.mode) mode, rotating every $([int]$proxyCfg.rotationEvery) messages."

# ------------------------------------------------------------ proxy pool ---
$pool = New-ProxyPool `
    -Mode ([string]$proxyCfg.mode) `
    -Provider ([string](Get-ConfigValue -Object $proxyCfg -Path 'provider' -Default '9proxy')) `
    -HostName ([string]$proxyCfg.host) `
    -Port ([int]$proxyCfg.port) `
    -UsernameTemplate ([string]$proxyCfg.usernameTemplate) `
    -Password '' `
    -PasswordProvider ${function:Get-ProxyPassword} `
    -Transport ([string]$proxyCfg.transport) `
    -LocalPorts @($proxyCfg.localPorts) `
    -Country ([string]$proxyCfg.country) `
    -State ([string]$proxyCfg.state) `
    -City ([string]$proxyCfg.city) `
    -Isp ([string]$proxyCfg.isp) `
    -Zone ([string](Get-ConfigValue -Object $proxyCfg -Path 'zone' -Default '')) `
    -SessionTimeMinutes ([int](Get-ConfigValue -Object $proxyCfg -Path 'sessionTimeMinutes' -Default 0)) `
    -ParamSeparator ([string](Get-ConfigValue -Object $proxyCfg -Path 'paramSeparator' -Default '-')) `
    -RotationEvery ([int]$proxyCfg.rotationEvery) `
    -EgressCheckHost ([string]$proxyCfg.egressCheck.host) `
    -EgressCheckPort ([int]$proxyCfg.egressCheck.port) `
    -EgressCheckPath ([string]$proxyCfg.egressCheck.path)

if ($RotateBeforeFirstBatch) { [void](Initialize-ProxyPool -Pool $pool) }
elseif (-not $DryRun) { [void](Get-ProxyEndpoint -Pool $pool) }

# ------------------------------------------------------------- accounts ----
# Every configured account is a sender. The engine uses the first one and
# moves to the next when an account stops accepting mail.
$smtpAccounts = @(Get-SmtpAccountList -Config $config)
foreach ($a in $smtpAccounts) {
    if ([int]$a.timeoutMs -le 0) { [void](Set-ConfigValue -Object $a -Path 'timeoutMs' -Value 30000) }
}
Write-RunLog -Path $logPath -Level 'INFO' -Message ("SMTP accounts: " + (($smtpAccounts | ForEach-Object { $_.label }) -join ', '))

# ------------------------------------------------------- message factory ---
$spamTerms = Get-SpamTermMap -Config $config
$script:hygieneHits = 0
$script:hygieneTerms = @{}

function New-CampaignMessage {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Variant
    )
    $email = ([string]$Row.email).Trim()
    $name = if ($Row.PSObject.Properties['name']) { ([string]$Row.name).Trim() } else { '' }
    $firstName = ($name -split '\s+')[0]

    $trackingUrl = New-TrackingUrl -LandingUrl ([string]$Variant.LinkBase) -Token $Token `
        -ParameterName ([string]$msgCfg.trackingParameter)
    $unsubUrl = Add-UnsubscribeUrl -UnsubscribeUrl ([string]$msgCfg.unsubscribeUrl) -Token $Token

    $values = @{
        email            = $email
        name             = $name
        first_name       = $firstName
        company          = if ($Row.PSObject.Properties['company']) { [string]$Row.company } else { '' }
        campaign         = $campaignId
        creative         = [string]$Variant.Id
        tracking_link    = $trackingUrl
        unsubscribe_link = $unsubUrl
        unsubscribe_url  = $unsubUrl
        brand_name       = $brandLabel
        company_name     = $brandLabel
        from_name        = [string]$msgCfg.fromName
        from_email       = [string]$msgCfg.fromEmail
        physical_address = [string]$msgCfg.physicalAddress
        logo_url         = [string](Get-ConfigValue -Object $msgCfg -Path 'logoUrl' -Default '')
        year             = (Get-Date).Year
    }
    foreach ($p in $Row.PSObject.Properties) {
        if (-not $values.ContainsKey($p.Name) -and $p.Name -ne 'email') {
            $values[$p.Name] = [string]$p.Value
        }
    }

    # The wording filter runs before the placeholders are filled, so a token
    # is never mangled and a link is never rewritten.
    $subject = [string]$Variant.Subject
    $html = [string]$Variant.Html
    if ($spamTerms.Count -gt 0) {
        $h1 = Invoke-ContentHygiene -Text $subject -Terms $spamTerms
        $subject = $h1.Text
        $h2 = Invoke-ContentHygiene -Text $html -Terms $spamTerms -Html
        $html = $h2.Text
        foreach ($c in @($h1.Changes) + @($h2.Changes)) {
            $script:hygieneHits += $c.Count
            $script:hygieneTerms[$c.Term] = $c.Count
        }
    }

    $subject = Expand-Tokens -Text $subject -Values $values
    $html = Expand-Tokens -Text $html -Values $values
    $html = $html.Replace('{{tracking_link}}', $trackingUrl).Replace('{{unsubscribe_link}}', $unsubUrl)
    $html = $html.Replace('{{subject}}', $subject)

    $text = if ($Variant.Text) {
        (Expand-Tokens -Text ([string]$Variant.Text) -Values $values).
            Replace('{{tracking_link}}', $trackingUrl).Replace('{{unsubscribe_link}}', $unsubUrl)
    }
    else { ConvertTo-PlainText -Html $html }

    $msg = New-MimeMessage `
        -FromName ([string]$msgCfg.fromName) `
        -FromEmail ([string]$msgCfg.fromEmail) `
        -ToEmail $email `
        -ToName $name `
        -Subject $subject `
        -HtmlBody $html `
        -TextBody $text `
        -ReplyTo ([string]$msgCfg.replyTo) `
        -ListUnsubscribe ([string]$msgCfg.listUnsubscribe) `
        -PhysicalAddress ([string]$msgCfg.physicalAddress) `
        -CampaignId $campaignId `
        -MessageIdHost ([string]$msgCfg.messageIdHost)

    return [PSCustomObject]@{
        Message = $msg
        TrackingUrl = $trackingUrl
        UnsubscribeUrl = $unsubUrl
        Token = $Token
        VariantId = [string]$Variant.Id
        LinkBase = [string]$Variant.LinkBase
    }
}

# ------------------------------------------------------------- planning ----
# Domain scoping. When allowedDomains is set, only recipients on those domains
# are contacted; anything else is skipped and reported. This is a guard rail
# so a campaign can never stray onto an unintended audience.
$allowedDomains = @(Get-ConfigValue -Object $msgCfg -Path 'allowedDomains' -Default @()) |
    ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ }
$blockedDomains = @(Get-ConfigValue -Object $msgCfg -Path 'blockedDomains' -Default @()) |
    ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ }

if ($allowedDomains.Count -gt 0) {
    Write-RunLog -Path $logPath -Level 'INFO' -Message "Restricting recipients to: $($allowedDomains -join ', ')"
}
if ($blockedDomains.Count -gt 0) {
    Write-RunLog -Path $logPath -Level 'INFO' -Message "Excluded domains: $($blockedDomains -join ', ')"
}

$pending = New-Object System.Collections.Generic.List[object]
$skippedByDomain = 0
foreach ($row in $rows) {
    $email = ([string]$row.email).Trim()
    if ([string]::IsNullOrWhiteSpace($email)) { continue }
    if (Test-Suppressed -State $state -Email $email) {
        [void](Add-Outcome -Supervisor $supervisor -Email $email -Status 'skipped' -Code 'suppressed' -Message 'On suppression list')
        continue
    }
    if ($Resume -and (Test-Processed -State $state -Email $email)) { continue }

    $rcptDomain = ''
    if ($email -match '@([^@]+)$') { $rcptDomain = $Matches[1].ToLowerInvariant() }
    if ($allowedDomains.Count -gt 0 -and -not ($allowedDomains -contains $rcptDomain)) {
        $skippedByDomain++
        [void](Add-Outcome -Supervisor $supervisor -Email $email -Status 'skipped' -Code 'domain-not-allowed' -Message "Recipient domain '$rcptDomain' is not in the allowed list.")
        continue
    }
    if ($blockedDomains.Count -gt 0 -and ($blockedDomains -contains $rcptDomain)) {
        $skippedByDomain++
        [void](Add-Outcome -Supervisor $supervisor -Email $email -Status 'skipped' -Code 'domain-blocked' -Message "Recipient domain '$rcptDomain' is on the excluded list.")
        continue
    }
    [void]$pending.Add($row)
}
if ($skippedByDomain -gt 0) {
    Write-RunLog -Path $logPath -Level 'WARN' -Message "Skipped $skippedByDomain recipient(s) by domain scope."
}

if ($MaxMessages -gt 0 -and $pending.Count -gt $MaxMessages) {
    $pending = @($pending | Select-Object -First $MaxMessages)
}

Write-RunLog -Path $logPath -Level 'INFO' -Message "Planned $($pending.Count) messages in batches of $effectiveBatchSize."

# ------------------------------------------------------------- dry run -----
if ($DryRun) {
    $previewDir = Join-Path $projectRoot 'preview'
    [void](New-DirectoryIfMissing $previewDir)
    $previewPath = Join-Path $previewDir "preview-$runStamp.eml"
    $plan = @()
    $sample = $pending | Select-Object -First 1
    if ($sample) {
        $tok = New-TrackingToken -Email ([string]$sample.email) -CampaignId $campaignId
        $firstVariant = $variantDefs[0]
        $built = New-CampaignMessage -Row $sample -Token $tok -Variant $firstVariant
        $built.Message.Raw | Set-Content -LiteralPath $previewPath -Encoding UTF8 -NoNewline
        $pf = Invoke-Preflight -Config $config -Message $built.Message -RecipientEmail ([string]$sample.email) `
            -TrackingUrl $built.TrackingUrl -TrackingBaseUrl ([string]$firstVariant.LinkBase) `
            -UnsubscribeUrl $built.UnsubscribeUrl -UnsubscribeBaseUrl ([string]$msgCfg.unsubscribeUrl) `
            -CheckUrls:(-not $SkipUrlChecks)
        Write-RunLog -Path $logPath -Level 'INFO' -Message "Preview written to $previewPath"
        Write-Host ''
        Write-Host '--- PREFLIGHT ---' -ForegroundColor Cyan
        foreach ($f in $pf.Findings) {
            $c = if ($f.Severity -eq 'error') { 'Red' } else { 'Yellow' }
            Write-Host ("  [{0}] {1}: {2}" -f $f.Severity.ToUpperInvariant(), $f.Code, $f.Detail) -ForegroundColor $c
        }
        if ($pf.Passed) { Write-Host '  RESULT: PASSED' -ForegroundColor Green }
        else { Write-Host '  RESULT: BLOCKED' -ForegroundColor Red }

        Write-Host ''
        Write-Host '--- CREATIVE ROTATION PLAN ---' -ForegroundColor Cyan
        for ($i = 0; $i -lt $variantDefs.Count; $i++) {
            $v = $variantDefs[$i]
            $firstBlock = ($i * $creativeRotateEvery) + 1
            $lastBlock = (($i + 1) * $creativeRotateEvery)
            Write-Host ("  block {0,2}: variant '{1}'  messages {2}-{3}" -f ($i + 1), $v.Id, $firstBlock, $lastBlock) -ForegroundColor Gray
            Write-Host ("             link  : {0}" -f $v.LinkBase) -ForegroundColor DarkGray
        }
        if ($spamTerms.Count -gt 0) {
            Write-Host ''
            Write-Host '--- WORDING FILTER ---' -ForegroundColor Cyan
            Write-Host ("  terms in the built-in list : {0}" -f $spamTerms.Count) -ForegroundColor Gray
            if ($script:hygieneHits -gt 0) {
                Write-Host ("  replaced in the preview     : {0} occurrence(s)" -f $script:hygieneHits) -ForegroundColor Yellow
                foreach ($k in ($script:hygieneTerms.Keys | Sort-Object)) {
                    Write-Host ("    {0,-24} x{1}" -f $k, $script:hygieneTerms[$k]) -ForegroundColor DarkGray
                }
            }
            else {
                Write-Host '  replaced in the preview     : 0' -ForegroundColor Green
            }
        }
    }
    $planObj = [PSCustomObject]@{
        runId = $supervisor.RunId
        dryRun = $true
        product = 'MAIL MOWAFAK'
        brand = $brandLabel
        clientId = $clientKey
        campaignId = $campaignId
        plannedMessages = $pending.Count
        batchSize = $effectiveBatchSize
        batches = [Math]::Ceiling($pending.Count / $effectiveBatchSize)
        rotationEvery = $pool.RotationEvery
        creativeRotateEvery = $creativeRotateEvery
        allowedDomains = @($allowedDomains)
        smtpAccounts = @($smtpAccounts | ForEach-Object { $_.label })
        variants = @($variantDefs | ForEach-Object {
                [PSCustomObject]@{ id = $_.Id; subject = $_.Subject; link = $_.LinkBase }
            })
        proxyMode = $pool.Mode
        wordingReplacements = $script:hygieneHits
        previewPath = $previewPath
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $planPath = Join-Path $logDir "plan-$runStamp.json"
    $planObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $planPath -Encoding UTF8
    Write-Host ''
    Write-Host "Dry run complete. Plan: $planPath" -ForegroundColor Green
    Write-Host "Nothing was sent." -ForegroundColor Green
    exit 0
}

# ------------------------------------------------------------ sending ------
$sentThisBatch = 0
$failedThisBatch = 0
$batchIndex = $state.BatchIndex
$session = $null
$currentIp = ''
$totalPlanned = $pending.Count
$processedCount = 0
$script:accountIndex = 0
$script:sessionAccount = -1

function Close-CurrentSession {
    if ($script:session) {
        Close-SmtpSession -Session $script:session
        $script:session = $null
        $script:sessionAccount = -1
    }
}

function Send-WithFailover {
    <#
      Sends one message and keeps the campaign going when an account stops
      accepting mail. A session that dies, an authentication error or a
      temporary rejection moves the campaign to the next configured account
      and the message is sent again from there.
    #>
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$RawMessage,
        [Parameter(Mandatory)]$Endpoint
    )

    $attempts = 0
    $result = $null
    while ($true) {
        $account = $smtpAccounts[$script:accountIndex]
        try {
            if (-not $script:session -or $script:sessionAccount -ne $script:accountIndex) {
                Close-CurrentSession
                $script:sessionAccount = $script:accountIndex
                $script:session = New-SmtpSession `
                    -HostName ([string]$account.host) `
                    -Port ([int]$account.port) `
                    -Username ([string]$account.username) `
                    -Password (Get-SmtpPassword -Account $account) `
                    -HeloDomain ([string]$account.heloDomain) `
                    -Encryption ([string]$account.encryption) `
                    -Transport $Endpoint.Transport `
                    -ProxyHost $Endpoint.ProxyHost `
                    -ProxyPort $Endpoint.ProxyPort `
                    -ProxyUsername $Endpoint.Username `
                    -ProxyPassword $Endpoint.Password `
                    -TimeoutMs ([int]$account.timeoutMs)
                Write-RunLog -Path $logPath -Level 'DEBUG' -Message "SMTP session opened as '$($account.label)' via $($Endpoint.Label)"
            }
            # The envelope sender has to match the account that authenticated:
            # the relay rejects MAIL FROM otherwise.
            $envelope = if ($account.username -match '@') { [string]$account.username } else { [string]$msgCfg.fromEmail }
            $result = Send-SmtpMessage -Session $script:session -EnvelopeFrom $envelope -EnvelopeTo $Email -RawMessage $RawMessage
        }
        catch {
            $result = [PSCustomObject]@{
                Recipient = $Email
                Sent = $false
                Code = -1
                Message = $_.Exception.Message
                Stage = 'session'
            }
        }
        if ($result.Sent) { return $result }

        # Only a transport or authentication problem is worth moving to the
        # next account. A rejected recipient stays on this account.
        $movable = @(-1, 421, 450, 451, 535)
        if (($movable -notcontains $result.Code) -or ($attempts -ge ($smtpAccounts.Count - 1))) {
            return $result
        }
        $attempts++
        $failed = $smtpAccounts[$script:accountIndex]
        $script:accountIndex = ($script:accountIndex + 1) % $smtpAccounts.Count
        Close-CurrentSession
        $next = $smtpAccounts[$script:accountIndex]
        Write-RunLog -Path $logPath -Level 'WARN' -Message "SMTP account '$($failed.label)' failed with [$($result.Code)] $($result.Message); switching to '$($next.label)'."
    }
}

try {
    foreach ($row in $pending) {
        $email = ([string]$row.email).Trim()
        $token = if ($row.PSObject.Properties['link_token'] -and $row.link_token) {
            [string]$row.link_token
        }
        else { New-TrackingToken -Email $email -CampaignId $campaignId }

        # --- rotate the creative (and its link) every N messages ---
        if ($creativeCounter -ge $creativeRotateEvery) {
            $creativeCounter = 0
            $creativeBlock++
            $nextVariant = $variantDefs[$creativeBlock % $variantDefs.Count]
            Write-RunLog -Path $logPath -Level 'INFO' -Message "Creative rotated -> variant '$($nextVariant.Id)' (link: $($nextVariant.LinkBase))"
        }
        $creativeCounter++
        $variant = $variantDefs[$creativeBlock % $variantDefs.Count]

        $built = New-CampaignMessage -Row $row -Token $token -Variant $variant

        # --- preflight for this message ---
        $pf = Invoke-Preflight -Config $config -Message $built.Message -RecipientEmail $email `
            -TrackingUrl $built.TrackingUrl -TrackingBaseUrl ([string]$variant.LinkBase) `
            -UnsubscribeUrl $built.UnsubscribeUrl -UnsubscribeBaseUrl ([string]$msgCfg.unsubscribeUrl) `
            -CheckUrls:(-not $SkipUrlChecks)
        if (-not $pf.Passed) {
            $detail = (($pf.Findings | Where-Object { $_.Severity -eq 'error' } | ForEach-Object { $_.Code }) -join ', ')
            Write-RunLog -Path $logPath -Level 'ERROR' -Message "Preflight blocked $email : $detail"
            [void](Add-Outcome -Supervisor $supervisor -Email $email -Status 'skipped' -Code 'preflight' -Message $detail -EgressIp $currentIp -BatchIndex $batchIndex -Variant $variant.Id)
            Mark-Processed -State $state -Email $email
            $processedCount++
            continue
        }

        # --- rotate if the batch quota is reached ---
        $rotated = Update-ProxyRotation -Pool $pool
        if ($rotated) {
            Close-CurrentSession
            $state.Rotations++
            Write-RunLog -Path $logPath -Level 'INFO' -Message "Rotated egress IP -> $($pool.CurrentEgressIp) (session $($pool.CurrentSessionId))"
        }

        $endpoint = Get-CurrentEndpoint -Pool $pool
        $currentIp = Get-PoolEgressLabel -Pool $pool

        # --- send, with a second account when the first one stops working ---
        $res = Send-WithFailover -Email $email -RawMessage $built.Message.Raw -Endpoint $endpoint

        if ($res.Sent) {
            $sentThisBatch++
            $state.SentCount++
            [void](Add-ProxyMessage -Pool $pool)
            [void](Add-Outcome -Supervisor $supervisor -Email $email -Status 'sent' -Code '250' -Message $res.Message -EgressIp $currentIp -BatchIndex $batchIndex -Variant $variant.Id)
            # The relay's own reply is kept in the log so a run can be audited
            # later without guessing what the server actually answered.
            Write-RunLog -Path $logPath -Level 'INFO' -Message "sent $email [$($res.Code)] $($res.Message)"
        }
        else {
            $failedThisBatch++
            $state.FailedCount++
            [void](Add-Outcome -Supervisor $supervisor -Email $email -Status 'failed' -Code ([string]$res.Code) -Message $res.Message -EgressIp $currentIp -BatchIndex $batchIndex -Variant $variant.Id)
            Write-RunLog -Path $logPath -Level 'WARN' -Message "failed $email : [$($res.Code)] $($res.Message)"

            # hard bounce -> suppress so it is never retried
            if ($res.Code -ge 550 -and $res.Code -lt 600) {
                [void](Add-Suppression -State $state -Email $email -Reason "smtp-$($res.Code)")
            }
            # session may be unusable after a protocol-level error
            if ($res.Code -lt 0 -or $res.Code -eq 421) { Close-CurrentSession }
        }

        Mark-Processed -State $state -Email $email
        $processedCount++

        # --- batch boundary ---
        if (($sentThisBatch + $failedThisBatch) -ge $effectiveBatchSize) {
            Close-CurrentSession
            Add-BatchRecord -Supervisor $supervisor -Index $batchIndex -EgressIp $currentIp `
                -EndpointLabel $endpoint.Label -Sent $sentThisBatch -Failed $failedThisBatch
            $batchIndex++
            $state.BatchIndex = $batchIndex
            $sentThisBatch = 0
            $failedThisBatch = 0
            # The next batch starts on the next account, so a provider that
            # starts throttling one mailbox does not stop the campaign.
            if ($smtpAccounts.Count -gt 1) {
                $script:accountIndex = ($script:accountIndex + 1) % $smtpAccounts.Count
                Write-RunLog -Path $logPath -Level 'INFO' -Message "Next batch uses SMTP account '$($smtpAccounts[$script:accountIndex].label)'."
            }
            Save-RunState -State $state
            Save-SuppressionList -State $state
            Write-RunLog -Path $logPath -Level 'INFO' -Message "Batch $batchIndex complete. Checkpoint saved."
        }

        # --- pacing ---
        $delayMs = [int]$batchCfg.delayBetweenMessagesMs
        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
    }
}
finally {
    Close-CurrentSession
}

if ($sentThisBatch -gt 0 -or $failedThisBatch -gt 0) {
    $ep = Get-CurrentEndpoint -Pool $pool
    Add-BatchRecord -Supervisor $supervisor -Index $batchIndex -EgressIp $currentIp `
        -EndpointLabel $ep.Label -Sent $sentThisBatch -Failed $failedThisBatch
}

Save-RunState -State $state
Save-SuppressionList -State $state

$meta = @{
    clientId = $clientKey
    brand = $brandLabel
    wordingReplacements = $script:hygieneHits
}
$report = Write-SupervisorReport -Supervisor $supervisor -RotationHistory $pool.History -Brand $brandLabel -Meta $meta
Write-Host ''
Write-Host (Format-SupervisorReport -Report $report) -ForegroundColor Cyan
Write-Host ''
Write-Host "Log    : $logPath"
Write-Host "Report : $reportPath"
