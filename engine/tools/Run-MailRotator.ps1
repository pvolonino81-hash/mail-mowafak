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
  Run-MailRotator.ps1 - start a campaign without typing secrets into the config.

  The passwords are asked for interactively, masked on screen, and kept in the
  process memory only. They are placed in the environment of the child process
  that actually sends the mail, and removed from this session immediately
  afterward. Nothing is written to disk, to the config file or to the logs.

  With a client profile the sender, the brand, the message and the audience
  all come from that profile, and every configured SMTP account is asked for.

  Usage:
      .\tools\Run-MailRotator.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt
      .\tools\Run-MailRotator.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt -DryRun
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$ClientId = '',
    [string]$ClientPath = '',
    [string]$RecipientsPath = '',
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$SkipUrlChecks,
    [int]$MaxMessages = 0,
    [int]$BatchSize = 0,
    # Ask again even when the variable is already set in this session.
    [switch]$Force
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'lib\Common.ps1')
. (Join-Path $projectRoot 'lib\Client.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $projectRoot 'config\config.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ------------------------------------------------------------------ client --
# The client profile is merged onto the base configuration, so the accounts
# and the passwords that are needed are known before anything is started.
$resolvedClientPath = Resolve-ClientProfilePath -ProjectRoot $projectRoot -ClientId $ClientId -ClientPath $ClientPath
$clientLabel = ''
if ($resolvedClientPath) {
    $profile = Get-ClientProfile -Path $resolvedClientPath
    $config = Merge-ClientConfig -BaseConfig $config -Profile $profile.Data
    $clientLabel = if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $ClientId } else { $profile.Id }
    if ([string]::IsNullOrWhiteSpace($clientLabel)) { $clientLabel = $profile.Name }
}

# ---------------------------------------------------------------------------
# Which secrets does this configuration actually need?
# A dry run never opens a session, so it never needs the SMTP password.
# ---------------------------------------------------------------------------
$needed = New-Object System.Collections.Generic.List[object]
$seenEnv = @{}

foreach ($account in @(Get-SmtpAccountList -Config $config)) {
    $envName = [string]$account.passwordEnv
    if ([string]::IsNullOrWhiteSpace($envName)) { continue }
    if ($seenEnv.ContainsKey($envName)) { continue }
    $seenEnv[$envName] = $true
    if (-not $DryRun) {
        $provider = Get-SmtpProvider -Name ([string]$account.provider) -Username ([string]$account.username)
        $needed.Add([PSCustomObject]@{ Name = $envName; Label = "$($provider.Label) (SMTP) password" })
    }
}

$proxyEnv = [string](Get-ConfigValue -Object $config -Path 'proxy.passwordEnv' -Default '')
$proxyNeeded = $false
if (-not [string]::IsNullOrWhiteSpace($proxyEnv)) {
    $proxyMode = [string](Get-ConfigValue -Object $config -Path 'proxy.mode' -Default 'none')
    # A dry run opens no tunnel and no session, so it needs no proxy secret.
    $proxyNeeded = ($proxyMode -ne 'none') -and (-not $DryRun)
}
if ($proxyNeeded) {
    $proxyProvider = [string](Get-ConfigValue -Object $config -Path 'proxy.provider' -Default '9proxy')
    $proxySpec = Get-ProxyProvider -Name $proxyProvider
    $needed.Add([PSCustomObject]@{ Name = $proxyEnv; Label = "$($proxySpec.Label) password" })
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][securestring]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-Secret {
    <#
      Read a secret without echoing it.

      On an interactive console the prompt is masked. When the input is
      redirected - a pipe, a scheduled job, an automated test - Read-Host
      blocks in Windows PowerShell 5.1, so the line is read from the console
      input stream instead. A redirected line is never printed back.
    #>
    param([Parameter(Mandatory)][string]$Label)

    if ([Console]::IsInputRedirected) {
        Write-Host ("  {0}" -f $Label) -NoNewline
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { throw "No input was supplied for $Label." }
        return (ConvertTo-SecureString -String $line -AsPlainText -Force)
    }
    return (Read-Host -AsSecureString -Prompt "  $Label")
}

Write-Host ''
Write-Host '  MAILROTATOR  -  secure launcher' -ForegroundColor Cyan
if ($clientLabel) { Write-Host "  client  : $clientLabel" -ForegroundColor Cyan }
Write-Host ''

if ($needed.Count -eq 0) {
    Write-Host '  No interactive password is required for this run.' -ForegroundColor DarkGray
}
else {
    Write-Host '  The passwords below are masked, held in memory only, and are not' -ForegroundColor DarkGray
    Write-Host '  written to the config, the logs or any file.' -ForegroundColor DarkGray
    Write-Host ''
}

$restore = @{}
foreach ($item in $needed) {
    $existing = [Environment]::GetEnvironmentVariable($item.Name)
    if (-not $Force -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host ("  {0}: using the value already set in this session." -f $item.Label) -ForegroundColor DarkGray
        continue
    }
    $secure = Read-Secret -Label $item.Label
    $plain = ConvertFrom-SecureStringPlain -Secure $secure
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw "No password was entered for $($item.Name)."
    }
    $restore[$item.Name] = $existing
    [Environment]::SetEnvironmentVariable($item.Name, $plain)
    $plain = $null
}

$sendScript = Join-Path $projectRoot 'Send-Mail.ps1'

# Switch parameters have to be passed to the child process as bare flags.
# Passing "-SkipUrlChecks $true" makes powershell -File bind the string
# "True" to the switch, which fails.
$argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sendScript,
    '-ConfigPath', $ConfigPath
)
if (-not [string]::IsNullOrWhiteSpace($resolvedClientPath)) {
    $argList += @('-ClientPath', $resolvedClientPath)
}
if (-not [string]::IsNullOrWhiteSpace($clientLabel)) {
    $argList += @('-ClientId', $clientLabel)
}
if (-not [string]::IsNullOrWhiteSpace($RecipientsPath)) { $argList += @('-RecipientsPath', $RecipientsPath) }
if ($DryRun)            { $argList += '-DryRun' }
if ($Resume)            { $argList += '-Resume' }
if ($SkipUrlChecks)     { $argList += '-SkipUrlChecks' }
if ($MaxMessages -gt 0) { $argList += @('-MaxMessages', [string]$MaxMessages) }
if ($BatchSize -gt 0)   { $argList += @('-BatchSize', [string]$BatchSize) }

$exitCode = 0
try {
    # The child inherits the environment, so the secrets reach Send-Mail.ps1
    # without them ever being written anywhere.
    & powershell @argList
    $exitCode = $LASTEXITCODE
}
finally {
    foreach ($name in $restore.Keys) {
        [Environment]::SetEnvironmentVariable($name, $restore[$name])
    }
    Write-Host ''
    Write-Host '  Passwords cleared from this session.' -ForegroundColor DarkGray
}

exit $exitCode
