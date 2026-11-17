<#
.SYNOPSIS
    Unlock a FleetDeck-managed Windows endpoint without its login password.

.DESCRIPTION
    The FleetDeck agent service runs as LocalSystem, so the terminal that the
    Commander opens for a device already runs with SYSTEM rights. That is the
    supported way back into a machine whose local password was lost - no
    password is guessed, cracked or reset on disk.

    It either resets the password of an existing local account or creates a
    temporary local administrator (recommended), and leaves an audit log.

.PARAMETER Account
    Existing local account to unlock. Auto-detected when omitted.

.PARAMETER NewPassword
    Password applied to the target account.

.PARAMETER TempUser
    Temporary administrator created when the account cannot be unlocked.

.EXAMPLE
    .\fd-unlock-account.ps1 -NewPassword 'Xk7-Remote!2026'
#>
[CmdletBinding()]
param(
    [string]$Account = '',
    [Parameter(Mandatory)][string]$NewPassword,
    [string]$TempUser = 'FD-Reset',
    [switch]$StatusOnly,
    [switch]$RemoveTempUser
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\ProgramData\FleetDeck'
if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
$logFile = Join-Path $logDir ('unlock-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

function Write-Log([string]$Text) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $Text
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

Write-Log ('identity: ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
Write-Log ('privileges: ' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

# --- who is at the keyboard -------------------------------------------------
function Get-InteractiveUser {
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($explorer) {
            $owner = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue).User
            if ($owner) { return ($owner -split '\\')[0] }
        }
    } catch { }
    return ''
}

$localUsers = @(Get-LocalUser -ErrorAction SilentlyContinue)
Write-Log ('local accounts: ' + (($localUsers | ForEach-Object { $_.Name + '(' + $_.Enabled + ')' }) -join ', '))

if ($StatusOnly) { Write-Log ('log file: ' + $logFile); return }

if ($RemoveTempUser) {
    if (Get-LocalUser -Name $TempUser -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $TempUser -ErrorAction SilentlyContinue
        Write-Log ('temporary administrator removed: ' + $TempUser)
    } else { Write-Log ('no temporary administrator to remove: ' + $TempUser) }
    Write-Log ('log file: ' + $logFile)
    return
}

$target = $Account
if (-not $target) {
    $interactive = Get-InteractiveUser
    if ($interactive) {
        $match = $localUsers | Where-Object { $_.Name -ieq $interactive -or $_.Name -like ('*' + $interactive + '*') } | Select-Object -First 1
        if ($match) { $target = $match.Name }
    }
}
if (-not $target) { $target = ($localUsers | Where-Object { $_.Enabled -and $_.Name -notmatch '^(Guest|DefaultAccount|WDAGUtilityAccount)$' } | Select-Object -First 1).Name }

if ($target) {
    try {
        & net.exe user $target $NewPassword /active:yes | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log ('password reset for local account: ' + $target) }
        else { Write-Log ('net.exe user failed for ' + $target + ' (exit ' + $LASTEXITCODE + ')') }
    } catch { Write-Log ('reset error for ' + $target + ': ' + $_.Exception.Message) }
} else {
    Write-Log 'no local account could be detected'
}

if (-not (Get-LocalUser -Name $TempUser -ErrorAction SilentlyContinue)) {
    try {
        & net.exe user $TempUser $NewPassword /add /passwordchg:no | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & net.exe localgroup Administrators $TempUser /add | Out-Null
            Write-Log ('temporary administrator created: ' + $TempUser)
        } else { Write-Log ('could not create ' + $TempUser + ' (exit ' + $LASTEXITCODE + ')') }
    } catch { Write-Log ('temp account error: ' + $_.Exception.Message) }
} else {
    Write-Log ('temporary administrator already exists: ' + $TempUser)
}

Write-Log ('log file: ' + $logFile)
