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
  Test-Proxy.ps1 - check the proxy before a campaign.

  It opens the tunnel the way the sender does, reads the exit IP through it
  and rotates it, so the operator can see whether the family, the account and
  the targeting parameters produce the IP addresses that were expected.

  Usage:
      .\tools\Test-Proxy.ps1 -ClientId example -Count 3
      .\tools\Test-Proxy.ps1 -Count 2
#>
[CmdletBinding()]
param(
    [string]$ClientId = '',
    [string]$ClientPath = '',
    [string]$ConfigPath = '',
    [int]$Count = 3
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'lib\Common.ps1')
. (Join-Path $projectRoot 'lib\Client.ps1')
. (Join-Path $projectRoot 'lib\Proxy.ps1')
. (Join-Path $projectRoot 'lib\ProxyPool.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $projectRoot 'config\config.json'
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$resolved = Resolve-ClientProfilePath -ProjectRoot $projectRoot -ClientId $ClientId -ClientPath $ClientPath
if ($resolved) {
    $profile = Get-ClientProfile -Path $resolved
    $config = Merge-ClientConfig -BaseConfig $config -Profile $profile.Data
}

$proxyCfg = Resolve-ProxySettings -Config $config
if ($null -eq $proxyCfg) { throw 'The configuration has no "proxy" section.' }

$provider = [string](Get-ConfigValue -Object $proxyCfg -Path 'provider' -Default '9proxy')
$spec = Get-ProxyProvider -Name $provider
$mode = [string](Get-ConfigValue -Object $proxyCfg -Path 'mode' -Default 'none')
$hostName = [string](Get-ConfigValue -Object $proxyCfg -Path 'host' -Default '')
$port = [int](Get-ConfigValue -Object $proxyCfg -Path 'port' -Default 0)
$envName = [string](Get-ConfigValue -Object $proxyCfg -Path 'passwordEnv' -Default '')
$secret = ''
if (-not [string]::IsNullOrWhiteSpace($envName)) {
    $secret = [Environment]::GetEnvironmentVariable($envName)
}

Write-Host ''
Write-Host '  MAILROTATOR  -  proxy check' -ForegroundColor Cyan
Write-Host ''
Write-Host ("  family       : {0}" -f $spec.Label) -ForegroundColor Gray
Write-Host ("  mode         : {0}" -f $mode) -ForegroundColor Gray
Write-Host ("  host         : {0}:{1}" -f $hostName, $port) -ForegroundColor Gray
Write-Host ("  account      : {0}" -f [string](Get-ConfigValue -Object $proxyCfg -Path 'usernameTemplate' -Default '')) -ForegroundColor Gray
Write-Host ("  region       : {0}" -f [string](Get-ConfigValue -Object $proxyCfg -Path 'country' -Default '')) -ForegroundColor Gray
Write-Host ("  state / city : {0} / {1}" -f [string](Get-ConfigValue -Object $proxyCfg -Path 'state' -Default ''), [string](Get-ConfigValue -Object $proxyCfg -Path 'city' -Default '')) -ForegroundColor Gray
Write-Host ("  session      : {0} minute(s)" -f [int](Get-ConfigValue -Object $proxyCfg -Path 'sessionTimeMinutes' -Default 0)) -ForegroundColor Gray
Write-Host ("  password env : {0} ({1})" -f $envName, $(if ([string]::IsNullOrWhiteSpace($secret)) { 'not set' } else { 'set' })) -ForegroundColor Gray
Write-Host ''

if ($mode -eq 'none') {
    Write-Host '  The proxy mode is "none": the mail goes out with the connection IP.' -ForegroundColor Yellow
    exit 0
}
if ([string]::IsNullOrWhiteSpace($hostName)) {
    Write-Host '  No proxy host is configured.' -ForegroundColor Yellow
    exit 1
}
if (-not [string]::IsNullOrWhiteSpace($envName) -and [string]::IsNullOrWhiteSpace($secret)) {
    Write-Host ("  The environment variable '{0}' is not set." -f $envName) -ForegroundColor Yellow
    Write-Host '  Set it before running this check, otherwise the tunnel cannot authenticate.' -ForegroundColor Yellow
    exit 1
}

$pool = New-ProxyPool `
    -Mode $mode `
    -Provider $provider `
    -HostName $hostName `
    -Port $port `
    -UsernameTemplate ([string](Get-ConfigValue -Object $proxyCfg -Path 'usernameTemplate' -Default '')) `
    -Password $secret `
    -Transport ([string](Get-ConfigValue -Object $proxyCfg -Path 'transport' -Default 'http')) `
    -LocalPorts @((Get-ConfigValue -Object $proxyCfg -Path 'localPorts' -Default @())) `
    -Country ([string](Get-ConfigValue -Object $proxyCfg -Path 'country' -Default '')) `
    -State ([string](Get-ConfigValue -Object $proxyCfg -Path 'state' -Default '')) `
    -City ([string](Get-ConfigValue -Object $proxyCfg -Path 'city' -Default '')) `
    -Isp ([string](Get-ConfigValue -Object $proxyCfg -Path 'isp' -Default '')) `
    -Zone ([string](Get-ConfigValue -Object $proxyCfg -Path 'zone' -Default '')) `
    -SessionTimeMinutes ([int](Get-ConfigValue -Object $proxyCfg -Path 'sessionTimeMinutes' -Default 0)) `
    -ParamSeparator ([string](Get-ConfigValue -Object $proxyCfg -Path 'paramSeparator' -Default '-')) `
    -RotationEvery 1 `
    -EgressCheckHost ([string](Get-ConfigValue -Object $proxyCfg -Path 'egressCheck.host' -Default 'api.ipify.org')) `
    -EgressCheckPort ([int](Get-ConfigValue -Object $proxyCfg -Path 'egressCheck.port' -Default 443)) `
    -EgressCheckPath ([string](Get-ConfigValue -Object $proxyCfg -Path 'egressCheck.path' -Default '/'))

$seen = New-Object System.Collections.Generic.List[string]
for ($i = 1; $i -le [Math]::Max(1, $Count); $i++) {
    $ep = Get-ProxyEndpoint -Pool $pool
    $ip = Get-EgressIp -Pool $pool -Endpoint $ep
    if ([string]::IsNullOrWhiteSpace([string]$ip)) { $ip = '(not detected)' }
    [void]$seen.Add([string]$ip)
    Write-Host ("  {0}. {1}" -f $i, $ip) -ForegroundColor Green
    Write-Host ("     {0}" -f $ep.Label) -ForegroundColor DarkGray
}

$distinct = @($seen | Select-Object -Unique)
Write-Host ''
if ($distinct.Count -gt 1) {
    Write-Host ("  {0} different exit IP(s) - the rotation works." -f $distinct.Count) -ForegroundColor Green
}
else {
    Write-Host '  Every attempt used the same IP.' -ForegroundColor Yellow
    Write-Host '  Check the session parameter of your family, or raise sessionTimeMinutes.' -ForegroundColor Yellow
}
