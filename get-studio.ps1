# MAIL MOWAFAK - Studio downloader (Windows)
# Downloads the signed bundle, verifies its SHA-256 and extracts it.
# It never runs the program for you.

[CmdletBinding()]
param(
    [string]$Destination = "",
    [string]$Base = 'https://z4ln662j87l6x.space.mcode.io'
)

$ErrorActionPreference = "Stop"

$asset = "MailRotatorStudio-Portable.zip"
$sha = "e0cc3b00257baaded895549f4a0372edb274944d0712b98c58720c6037eb99bb"

if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = Join-Path (Get-Location) "MailRotatorStudio" }
[void](New-Item -ItemType Directory -Path $Destination -Force)
$target = Join-Path $Destination $asset
$url = "$Base/$asset"

Write-Host ("Downloading " + $url)
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) {
    & $curl.Source -fL --progress-bar -o $target $url
    if ($LASTEXITCODE -ne 0) { throw ("Download failed with exit code " + $LASTEXITCODE) }
} else {
    Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
}

$hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $sha) {
    try { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } catch { }
    throw ("Checksum mismatch. Expected " + $sha + ", got " + $hash)
}

Write-Host ""
Write-Host ("Saved    : " + $target)
Write-Host ("Size     : {0:N0} bytes" -f (Get-Item -LiteralPath $target).Length)
Write-Host ("SHA-256 : " + $hash + "   (verified)")
Write-Host ""
Write-Host "Unzip it, then double-click Start-Studio.cmd."
