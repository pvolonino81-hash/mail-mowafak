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
  Send-Campaign.ps1 - the door of the mailer.

  One client profile is one customer: its own brand, its own sender mailbox,
  its own message, its own audience, its own SMTP accounts and its own
  checkpoint. Nothing a recipient can see is decided by this program.

  Usage:
      .\tools\Send-Campaign.ps1 -List
      .\tools\Send-Campaign.ps1 -ClientId example -RecipientsPath .\data\recipients.txt -DryRun
      .\tools\Send-Campaign.ps1 -ClientId example -RecipientsPath .\data\recipients.txt
#>
[CmdletBinding()]
param(
    [string]$ClientId = '',
    [string]$ClientPath = '',
    [string]$RecipientsPath = '',
    [switch]$List,
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$SkipUrlChecks,
    [int]$MaxMessages = 0,
    [int]$BatchSize = 0,
    [switch]$Force
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'lib\Common.ps1')
. (Join-Path $projectRoot 'lib\Client.ps1')

$clientsDir = Join-Path $projectRoot 'clients'

function Get-ClientProfiles {
    <# Every client profile the project holds. #>
    $found = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $clientsDir)) { return $found.ToArray() }
    foreach ($dir in (Get-ChildItem -LiteralPath $clientsDir -Directory -ErrorAction SilentlyContinue)) {
        $file = Join-Path $dir.FullName 'client.json'
        if (Test-Path -LiteralPath $file) {
            try { $found.Add((Get-ClientProfile -Path $file)) } catch { }
        }
    }
    foreach ($file in (Get-ChildItem -LiteralPath $clientsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { $found.Add((Get-ClientProfile -Path $file.FullName)) } catch { }
    }
    return $found.ToArray()
}

if ($List) {
    $profiles = @(Get-ClientProfiles)
    Write-Host ''
    Write-Host '  MAIL MOWAFAK  -  clients' -ForegroundColor Cyan
    Write-Host ''
    if ($profiles.Count -eq 0) {
        Write-Host '  No client profile found in clients\.' -ForegroundColor Yellow
        exit 1
    }
    foreach ($p in $profiles) {
        $name = if ([string]::IsNullOrWhiteSpace($p.Name)) { '(no name)' } else { $p.Name }
        Write-Host ("  {0,-18} {1}" -f $p.Id, $name) -ForegroundColor Green
        Write-Host ("  {0,-18} {1}" -f '', $p.Path) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ('  Run one with:  .\tools\Send-Campaign.ps1 -ClientId <id> -RecipientsPath <file>') -ForegroundColor Gray
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ClientId) -and [string]::IsNullOrWhiteSpace($ClientPath)) {
    Write-Host ''
    Write-Host '  MAILROTATOR  -  a client is required' -ForegroundColor Yellow
    Write-Host '  Use -ClientId <id> or -ClientPath <file>. Run with -List to see the clients.' -ForegroundColor Yellow
    exit 1
}

$resolved = Resolve-ClientProfilePath -ProjectRoot $projectRoot -ClientId $ClientId -ClientPath $ClientPath
$profile = Get-ClientProfile -Path $resolved
$clientKey = Get-SafeClientKey -Value $ClientId
if ([string]::IsNullOrWhiteSpace($clientKey)) { $clientKey = Get-SafeClientKey -Value $profile.Id }

$config = Get-Content -LiteralPath (Join-Path $projectRoot 'config\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config = Merge-ClientConfig -BaseConfig $config -Profile $profile.Data

$brand = [string](Get-ConfigValue -Object $config -Path 'message.brandName' -Default $profile.Name)
$from = [string](Get-ConfigValue -Object $config -Path 'message.fromEmail' -Default '')
$domains = @(Get-ConfigValue -Object $config -Path 'message.allowedDomains' -Default @())
$accounts = @(Get-SmtpAccountList -Config $config)

Write-Host ''
Write-Host '  MAILROTATOR  -  campaign summary' -ForegroundColor Cyan
Write-Host ''
Write-Host ("  client        : {0}" -f $clientKey) -ForegroundColor Gray
Write-Host ("  brand         : {0}" -f $brand) -ForegroundColor Gray
Write-Host ("  sender        : {0}" -f $from) -ForegroundColor Gray
Write-Host ("  subject       : {0}" -f [string](Get-ConfigValue -Object $config -Path 'message.subject' -Default '')) -ForegroundColor Gray
Write-Host ("  template      : {0}" -f [string](Get-ConfigValue -Object $config -Path 'message.templatePath' -Default '')) -ForegroundColor Gray
Write-Host ("  landing page  : {0}" -f [string](Get-ConfigValue -Object $config -Path 'message.landingUrl' -Default '')) -ForegroundColor Gray
Write-Host ("  audience      : {0}" -f ($(if ($domains.Count -gt 0) { $domains -join ', ' } else { '(any domain)' }))) -ForegroundColor Gray
Write-Host ("  batch size    : {0}" -f [string](Get-ConfigValue -Object $config -Path 'batch.size' -Default '150')) -ForegroundColor Gray
foreach ($a in $accounts) {
    Write-Host ("  smtp account  : {0} ({1})" -f $a.label, $a.username) -ForegroundColor Gray
}
if ($accounts.Count -gt 1) {
    Write-Host '  the accounts are used in turn, and the next one takes over' -ForegroundColor DarkGray
    Write-Host '  when an account stops accepting mail.' -ForegroundColor DarkGray
}
Write-Host ("  state folder  : {0}" -f (Get-ClientStateDir -ProjectRoot $projectRoot -ClientId $clientKey)) -ForegroundColor DarkGray
Write-Host ''

$launcher = Join-Path $PSScriptRoot 'Run-MailRotator.ps1'
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-ClientPath', $resolved, '-ClientId', $clientKey)
if (-not [string]::IsNullOrWhiteSpace($RecipientsPath)) { $argList += @('-RecipientsPath', $RecipientsPath) }
if ($DryRun)            { $argList += '-DryRun' }
if ($Resume)            { $argList += '-Resume' }
if ($SkipUrlChecks)     { $argList += '-SkipUrlChecks' }
if ($Force)             { $argList += '-Force' }
if ($MaxMessages -gt 0) { $argList += @('-MaxMessages', [string]$MaxMessages) }
if ($BatchSize -gt 0)   { $argList += @('-BatchSize', [string]$BatchSize) }

& powershell @argList
exit $LASTEXITCODE
