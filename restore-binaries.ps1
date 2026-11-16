# restore-binaries.ps1
# Decodes the base64 assets that GitHub stores as text, so the signed
# integrity manifest of the engine can verify them again.
Stop = 'Stop'
C:\Users\Membe\.minimax\sessions\mvs_29b5a01776c14d09b65f7b910feb6c49\workspace\studio\ui = Split-Path -Parent System.Management.Automation.InvocationInfo.MyCommand.Path

$b64 = [System.IO.File]::ReadAllText((Join-Path $root 'engine/assets/mowafak-logo.png'.base64'))
$target = Join-Path $root 'engine/assets/mowafak-logo.png'
[void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
[System.IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($b64))
Write-Host ('restored ' + 'engine/assets/mowafak-logo.png')

$b64 = [System.IO.File]::ReadAllText((Join-Path $root 'engine/integrity/manifest.sig'.base64'))
$target = Join-Path $root 'engine/integrity/manifest.sig'
[void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
[System.IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($b64))
Write-Host ('restored ' + 'engine/integrity/manifest.sig')

$b64 = [System.IO.File]::ReadAllText((Join-Path $root 'engine/guide/assets/mowafak-logo.png'.base64'))
$target = Join-Path $root 'engine/guide/assets/mowafak-logo.png'
[void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
[System.IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($b64))
Write-Host ('restored ' + 'engine/guide/assets/mowafak-logo.png')
