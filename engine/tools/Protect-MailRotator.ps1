# ==============================================================================
<#
.SYNOPSIS
  Brands MAIL MOWAFAK with its banner and signs an integrity manifest that the
  program verifies at startup.

.DESCRIPTION
  What it does, in order:

    1. Creates (or reuses) an RSA-2048 key pair. The PRIVATE key is written
       OUTSIDE the project folder so it is never shipped with the package.
    2. Strips any previously injected banner, then injects a fresh branded
       header into every protectable source file.
    3. Computes a SHA-256 hash for each protected file.
    4. Writes integrity/manifest.json listing those hashes.
    5. Signs the manifest with RSA-SHA256 (PKCS#1 v1.5).
    6. Generates lib/Integrity.ps1, which embeds the public key, the signed
       manifest and the verification routine.

  Because verification uses only a public key, the private key is never
  distributed. Only someone holding it can re-sign after a legitimate change.

  The logo of the mailer is covered by the same manifest, so the mark that
  ships with the tool is the mark that was signed.

.PARAMETER ProjectRoot
  The MAIL MOWAFAK project folder. Defaults to the parent of this script.

.PARAMETER PrivateKeyPath
  Where to keep the private signing key. Defaults to a sibling folder
  outside the project so it cannot leak into the distributed zip.

.PARAMETER Brand
  Brand name printed on every protected file. This is the owner of the tool.
  It never appears in the messages that the tool sends: every campaign
  carries the brand of the client it was configured for.

.PARAMETER Product
  The name of the program. It is printed on every protected file and it
  is locked: the file that carries it (assets/product.json) is inside the
  signed manifest, so changing the name breaks the integrity check.
  It never appears in a sent message: every campaign carries the brand of
  the client it was configured for.

.PARAMETER LicensedTo
  Optional licensee line.

.PARAMETER RegenerateKey
  Create a new key pair, invalidating every previously signed build.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$PrivateKeyPath = '',
    [string]$Brand = 'Mowafak Store',
    [string]$Product = 'MAIL MOWAFAK',
    [string]$LicensedTo = '',
    [switch]$RegenerateKey
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    # this script lives in <ProjectRoot>/tools
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
    # the key lives outside the project; older builds kept it in a folder
    # named after the previous brand, so both locations are tried.
    $parent = Split-Path -Parent $ProjectRoot
    foreach ($candidate in @((Join-Path $parent 'SigningKey'), (Join-Path $parent 'MowafakStore-SigningKey'))) {
        if (Test-Path -LiteralPath $candidate) { $PrivateKeyPath = $candidate; break }
    }
    if ([string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
        $PrivateKeyPath = Join-Path $parent 'SigningKey'
    }
}

$START = 'MAILROTATOR_BANNER_START'
$END = 'MAILROTATOR_BANNER_END'
# Older builds were stamped with the MOWAFAK_STORE markers. Both sets are
# recognized so a re-brand can replace a banner of either shape.
$LEGACY_END = 'MOWAFAK_STORE_BANNER_END'

# ------------------------------------------------------------------ key ----
[void](New-Item -ItemType Directory -Path $PrivateKeyPath -Force)

# The key file name changed with the re-brand. The old name is still found so
# an existing build keeps the key it was signed with.
$privFile = ''
$pubFile = ''
foreach ($name in @('signing-private.xml', 'mowafak-private.xml')) {
    $candidate = Join-Path $PrivateKeyPath $name
    if (Test-Path -LiteralPath $candidate) { $privFile = $candidate; break }
}
if ($privFile -eq '') { $privFile = Join-Path $PrivateKeyPath 'signing-private.xml' }
$pubFile = Join-Path $PrivateKeyPath ([System.IO.Path]::GetFileName($privFile) -replace 'private', 'public')

if ($RegenerateKey -or -not (Test-Path -LiteralPath $privFile)) {
    Write-Host 'Generating RSA-2048 signing key pair...' -ForegroundColor Cyan
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
    $rsa.PersistKeyInCsp = $false
    [System.IO.File]::WriteAllText($privFile, $rsa.ToXmlString($true))
    [System.IO.File]::WriteAllText($pubFile, $rsa.ToXmlString($false))
    $rsa.Dispose()
    Write-Host "  private key : $privFile" -ForegroundColor DarkGray
    Write-Host "  public key  : $pubFile" -ForegroundColor DarkGray
    Write-Host '  Keep the private key. It is what lets you re-sign after a change.' -ForegroundColor Yellow
}
else {
    Write-Host "Using existing signing key: $privFile" -ForegroundColor DarkGray
}

# --------------------------------------------------------------- banner ----
function Get-BannerLines {
    param([string]$FileExtension, [string]$Brand, [string]$LicensedTo, [string]$Product = 'MAIL MOWAFAK')
    $lic = if ($LicensedTo) { $LicensedTo } else { $Brand }
    $bar = '=' * 78
    $mid = '-' * 78

    if ($FileExtension -eq '.html' -or $FileExtension -eq '.md') {
        return @(
            "<!-- $bar -->",
            "<!--   $START -->",
            "<!--   $($Brand.ToUpperInvariant())  -  Proprietary Software",
            "<!--   Product : $Product - SMTP bulk sender with rotating egress IPs",
            "<!--   Copyright (c) 2026 $Brand. All rights reserved.",
            "<!--   Licensed to: $lic",
            "<!--   $mid",
            "<!--   INTEGRITY PROTECTED. This file is covered by a signed manifest",
            "<!--   (RSA-2048 / SHA-256). Editing it, removing this header, or",
            "<!--   altering any protected file makes MAIL MOWAFAK refuse to run.",
            "<!--   The private signing key is NOT distributed with this package.",
            "<!--   $END -->",
            "<!-- $bar -->"
        )
    }

    # PowerShell / generic comment banner
    return @(
        "# $bar",
        "#   $START",
        "#   $($Brand.ToUpperInvariant())  -  Proprietary Software",
        "#   Product : $Product - SMTP bulk sender with rotating egress IPs",
        "#   Copyright (c) 2026 $Brand. All rights reserved.",
        "#   Licensed to: $lic",
        "#   $mid",
        "#   INTEGRITY PROTECTED. This file is covered by a signed manifest",
        "#   (RSA-2048 / SHA-256). Editing it, removing this header, or",
        "#   altering any protected file makes MAIL MOWAFAK refuse to run.",
        "#   The private signing key is NOT distributed with this package.",
        "#   $END",
        "# $bar"
    )
}

function Remove-Banner {
    <#
      Strips a previously injected banner so re-branding stays idempotent.
      The banner always sits at the very top of the file.
      Two shapes are handled: the current marked banner, and the earlier
      unmarked banner that used only the '====' bar lines.
    #>
    param([string]$Text)

    if ($Text -match ($END -replace '-', '\-') -or $Text -match 'MOWAFAK_STORE_BANNER_END') {
        $pattern = '(?s)\A.*?(?:MAILROTATOR|MOWAFAK_STORE)_BANNER_END[^\r\n]*(\r?\n)?[ \t]*(#|<!--)[ \t]*=+[ \t]*(-->)?[ \t]*(\r?\n)?'
        return ([regex]::Replace($Text, $pattern, '')).TrimStart("`r", "`n")
    }

    # Legacy banner: drop the leading '=' bar block (first bar line to second).
    $lines = $Text -split "`r?`n"
    if ($lines.Count -lt 3) { return $Text }
    if ($lines[0] -notmatch '^\s*(#|<!--)\s*=+') { return $Text }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(#|<!--)\s*=+') { $end = $i; break }
    }
    if ($end -lt 0) { return $Text }
    $rest = if ($end + 1 -le $lines.Count - 1) { $lines[($end + 1)..($lines.Count - 1)] } else { @() }
    return (($rest -join "`r`n")).TrimStart("`r", "`n")
}

function Add-Banner {
    param([string]$Text, [string[]]$Lines, [string]$Extension)
    $body = $Text -replace '^\s*', ''
    if ($Extension -eq '.html' -or $Extension -eq '.md') {
        return (($Lines -join "`r`n") + "`r`n" + $body)
    }
    return (($Lines -join "`r`n") + "`r`n" + $body)
}

# Files that carry the banner and take part in the integrity manifest.
# Code is protected. Configuration, templates and recipient data are NOT,
# because those are meant to be edited by the operator.
$protected = @(
    'Send-Mail.ps1',
    'README.md',
    'lib/Client.ps1',
    'lib/Common.ps1',
    'lib/Message.ps1',
    'lib/Preflight.ps1',
    'lib/Proxy.ps1',
    'lib/ProxyPool.ps1',
    'lib/Smtp.ps1',
    'lib/State.ps1',
    'lib/Supervisor.ps1',
    'tests/FakeSmtpServer.ps1',
    'tests/FakeHttpServer.ps1',
    'tests/Test-Integration.ps1',
    'tests/Test-Launcher.ps1',
    'tests/Test-Unit.ps1',
    'tools/Run-MailRotator.ps1',
    'tools/Send-Campaign.ps1',
    'tools/Test-Proxy.ps1'
)

# Binary assets that take part in the manifest but cannot carry a text
# banner. The logo of the mailer is here on purpose: it is hashed, so it
# cannot be swapped after the build was signed.
$protectedAssets = @(
    'assets/mowafak-logo.png',
    'assets/product.json'
)

Write-Host ''
Write-Host "Branding $($protected.Count) files..." -ForegroundColor Cyan
$stamped = 0
# Windows PowerShell 5.1 reads Get-Content without an explicit encoding using
# the ANSI code page, so a UTF-8 file would be decoded as CP1252 and re-encoded
# as UTF-8 on every stamp. That corrupts em dashes and arrows one layer deeper
# each run. Reading and writing as explicit UTF-8 keeps the file byte-exact.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($rel in $protected) {
    $full = Join-Path $ProjectRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { Write-Host "  skip (missing): $rel" -ForegroundColor DarkGray; continue }
    $text = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    $ext = [System.IO.Path]::GetExtension($rel)
    $text = Remove-Banner -Text $text
    $lines = Get-BannerLines -FileExtension $ext -Brand $Brand -LicensedTo $LicensedTo -Product $Product
    $text = Add-Banner -Text $text -Lines $lines -Extension $ext
    [System.IO.File]::WriteAllText($full, $text, $utf8NoBom)
    Write-Host "  stamped $rel" -ForegroundColor DarkGray
    $stamped++
}

# -------------------------------------------------------------- manifest ---
Write-Host ''
Write-Host 'Computing hashes and signing the manifest...' -ForegroundColor Cyan
$entries = [ordered]@{}
foreach ($rel in ($protected + $protectedAssets)) {
    $full = Join-Path $ProjectRoot $rel
    if (-not (Test-Path -LiteralPath $full)) {
        if ($protectedAssets -contains $rel) { Write-Host "  MISSING ASSET: $rel" -ForegroundColor Red }
        continue
    }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
    $entries[$rel] = $hash
}

$manifest = [ordered]@{
    brand       = $Brand
    licensedTo  = $LicensedTo
    createdUtc  = (Get-Date).ToUniversalTime().ToString('o')
    algorithm   = 'RSA-2048/SHA-256, PKCS#1 v1.5'
    fileCount   = $entries.Count
    files       = $entries
}
$manifestJson = $manifest | ConvertTo-Json -Depth 6
$manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$rsa.FromXmlString([System.IO.File]::ReadAllText($privFile))
$sig = $rsa.SignData($manifestBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$publicXml = $rsa.ToXmlString($false)
$rsa.Dispose()

$integrityDir = Join-Path $ProjectRoot 'integrity'
[void](New-Item -ItemType Directory -Path $integrityDir -Force)
[System.IO.File]::WriteAllBytes((Join-Path $integrityDir 'manifest.sig'), $sig)

# --------------------------------------------------- generate verifier -----
# The verifier embeds the public key and the signed manifest as base64 so the
# generated file contains no nested here-strings and nothing that needs
# escaping. Everything else is copied verbatim from the template.
$publicKeyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicXml))
$manifestB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($manifestJson))
$sigB64 = [Convert]::ToBase64String($sig)

$verifierTemplate = @'
# ==============================================================================
#   MAIL MOWAFAK  -  Integrity verifier.
#
#   This file holds the public key, the signed manifest and the check routine.
#   It is the trust anchor of the protection scheme: the private key that
#   signed the manifest is NOT distributed with this package.
#
#   The manifest is signed with RSA-2048 / SHA-256 (PKCS#1 v1.5).
#   Every protected file is then re-hashed and compared to the manifest.
# ==============================================================================

$script:ToolBrand = '__BRAND__'

# base64 so this file stays free of quoting and here-string hazards
$script:ToolPublicKeyB64 = '__PUBLIC_KEY_B64__'
$script:ToolManifestB64 = '__MANIFEST_B64__'
$script:ToolSignatureB64 = '__SIGNATURE__'

function Test-MailRotatorIntegrity {
    <#
      Verifies the signed manifest and every protected file.
      Returns a result object; on failure the caller must stop the program.
    #>
    [CmdletBinding()]
    param([string]$ProjectRoot = '')

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
    }
    $failures = New-Object System.Collections.Generic.List[string]

    $publicKeyXml = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ToolPublicKeyB64))
    $manifestJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ToolManifestB64))

    # --- 1. signature over the manifest ---
    $manifestObj = $null
    $sigOk = $false
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($publicKeyXml)
        $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)
        $sig = [Convert]::FromBase64String($script:ToolSignatureB64)
        $sigOk = $rsa.VerifyData($manifestBytes, $sig,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $rsa.Dispose()
    }
    catch {
        $failures.Add("Signature check could not run: $($_.Exception.Message)")
    }
    if (-not $sigOk -and $failures.Count -eq 0) {
        $failures.Add('The manifest signature is not valid. The manifest was altered.')
    }

    try { $manifestObj = $manifestJson | ConvertFrom-Json } catch { }

    # --- 2. per-file hashes ---
    if ($null -ne $manifestObj) {
        foreach ($prop in $manifestObj.files.PSObject.Properties) {
            $rel = $prop.Name
            $expected = [string]$prop.Value
            $full = Join-Path $ProjectRoot $rel
            if (-not (Test-Path -LiteralPath $full)) {
                $failures.Add("Protected file is missing: $rel")
                continue
            }
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $actual = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
            finally { $sha.Dispose() }
            if ($actual -ne $expected) {
                $failures.Add("Protected file was modified: $rel")
            }
        }
    }

    return [PSCustomObject]@{
        Passed   = ($failures.Count -eq 0)
        Brand    = $script:ToolBrand
        Failures = $failures.ToArray()
        Checked  = if ($null -ne $manifestObj) { $manifestObj.fileCount } else { 0 }
    }
}
'@

$verifier = $verifierTemplate.
    Replace('__BRAND__', $Brand).
    Replace('__PUBLIC_KEY_B64__', $publicKeyB64).
    Replace('__MANIFEST_B64__', $manifestB64).
    Replace('__SIGNATURE__', $sigB64)

[System.IO.File]::WriteAllText((Join-Path $ProjectRoot 'lib\Integrity.ps1'), $verifier)
Write-Host "  generated lib\Integrity.ps1" -ForegroundColor DarkGray

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  branded files : $stamped"
Write-Host "  protected     : $($entries.Count)"
Write-Host "  private key   : $privFile  (keep it out of the zip)"
