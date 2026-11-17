# build-package.ps1 - builds the portable package and the per-user installer.
#
#   .\build-package.ps1 -Workspace <root> -Out <dist folder>
#
# Produces:
#   MailRotatorStudio-Portable.zip   the unpacked studio (run Start-Studio.cmd)
#   MAIL-MOWAFAK-Setup.exe           self-extracting installer, current user only

[CmdletBinding()]
param(
    [string]$Workspace = (Split-Path -Parent $PSScriptRoot),
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $Workspace 'dist' }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$pkg = Join-Path $Workspace 'MailRotatorStudio'

Write-Host '[1/5] syncing server, ui and tools into the package'
robocopy (Join-Path $Workspace 'studio\server') (Join-Path $pkg 'server') /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
robocopy (Join-Path $Workspace 'studio\ui') (Join-Path $pkg 'ui') /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'tools') | Out-Null
foreach ($f in @('filter-leads.mjs','build-recipient-list.mjs','plan-campaign.mjs','set-smtp-profile.mjs','set-proxy-profile.mjs','campaign-watcher.mjs','fd-unlock-account.ps1')) {
    $src = Join-Path $Workspace ('studio\tools\' + $f)
    if (Test-Path $src) { Copy-Item $src (Join-Path $pkg 'tools') -Force }
}

Write-Host '[2/5] clearing the runtime folders that must not travel'
foreach ($d in @('engine\logs','engine\state','engine\preview')) {
    $p = Join-Path $pkg $d
    if (Test-Path $p) { Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
}
Get-ChildItem (Join-Path $pkg 'engine\data') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*.log' } | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host '[3/5] building the portable zip'
$payload = Join-Path $Out 'MailMowafak-payload.zip'
if (Test-Path $payload) { Remove-Item $payload -Force }
Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $payload -CompressionLevel Optimal -Force
$portable = Join-Path $Out 'MailRotatorStudio-Portable.zip'
if (Test-Path $portable) { Remove-Item $portable -Force }
Copy-Item $payload $portable -Force

Write-Host '[4/5] building the self-extracting installer (per user, no admin)'
Copy-Item (Join-Path $pkg 'install.cmd') $Out -Force
$setup = Join-Path $Out 'MAIL-MOWAFAK-Setup.exe'
$sed = Join-Path $Out 'setup.sed'
$sedText = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=MAIL MOWAFAK is installed for your user account. The console window will open.
TargetName=$setup
FriendlyName=MAIL MOWAFAK
AppLaunched=install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=install.cmd
UserQuietInstCmd=install.cmd
SourceFiles=SourceFiles
[SourceFiles]
SourceFiles0=$payload
SourceFiles1=$(Join-Path $Out 'install.cmd')
[Strings]
FILE0="MailMowafak-payload.zip"
FILE1="install.cmd"
"@
Set-Content -LiteralPath $sed -Value $sedText -Encoding ASCII
$ie = Join-Path $env:WINDIR 'System32\iexpress.exe'
if (Test-Path $setup) { Remove-Item $setup -Force }
$proc = Start-Process -FilePath $ie -ArgumentList '/N', $sed -PassThru -Wait -WindowStyle Hidden
if (-not (Test-Path $setup)) { throw 'the installer was not produced' }

Write-Host '[5/5] result'
Get-ChildItem $Out -File | Where-Object { $_.Extension -in '.zip', '.exe' } |
    Select-Object Name, @{n='MB';e={[math]::Round($_.Length / 1MB, 2)}}, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ('portable   : ' + $portable)
Write-Host ('installer  : ' + $setup)
