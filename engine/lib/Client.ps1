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
Set-StrictMode -Version 1.0

<#
  Client layer.

  A "client" is one customer of the engine: one brand, one sender mailbox,
  one message, one SMTP account (or several), one audience and one isolated
  state directory. Nothing about a client is baked into the code; all of it
  comes from a JSON profile under clients/<id>/client.json.

  This file holds:
    - the SMTP provider table (Optimum, Suddenlink, Outlook, Office365)
    - the merge of a client profile onto the base configuration
    - path and state-directory resolution, isolated per client
    - recipient list import (CSV or a plain text file of addresses)
    - the short-link code generator
#>

# ---------------------------------------------------------------- providers --
# The relay families the engine is built for. A client only names the family
# and the account; host, port, encryption and HELO domain come from here, so
# the operator cannot mistype a server.
$script:SmtpProviders = @{
    'optimum' = [PSCustomObject]@{
        Key         = 'optimum'
        Label       = 'Optimum Online'
        Host        = 'mail.optonline.net'
        Port        = 587
        Encryption  = 'starttls'
        HeloDomain  = 'optonline.net'
    }
    'suddenlink' = [PSCustomObject]@{
        Key         = 'suddenlink'
        Label       = 'Suddenlink'
        Host        = 'mail.optonline.net'
        Port        = 587
        Encryption  = 'starttls'
        HeloDomain  = 'suddenlink.net'
    }
    'outlook' = [PSCustomObject]@{
        Key         = 'outlook'
        Label       = 'Outlook / Hotmail'
        Host        = 'smtp-mail.outlook.com'
        Port        = 587
        Encryption  = 'starttls'
        HeloDomain  = 'outlook.com'
    }
    'office365' = [PSCustomObject]@{
        Key         = 'office365'
        Label       = 'Microsoft 365'
        Host        = 'smtp.office365.com'
        Port        = 587
        Encryption  = 'starttls'
        HeloDomain  = 'office365.com'
    }
}

function Get-SmtpProvider {
    <#
      Resolves a provider by name, or detects it from the account address when
      the name is "auto" or empty.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = 'auto',
        [string]$Username = ''
    )

    $key = ([string]$Name).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq 'auto') {
        $u = ([string]$Username).Trim().ToLowerInvariant()
        if ($u -like '*@suddenlink.net')      { $key = 'suddenlink' }
        elseif ($u -like '*@optonline.net')   { $key = 'optimum' }
        elseif ($u -like '*@office365.com')   { $key = 'office365' }
        elseif ($u -like '*@outlook.com' -or $u -like '*@hotmail.com' -or $u -like '*@live.com') { $key = 'outlook' }
        else { $key = 'optimum' }
    }
    if (-not $script:SmtpProviders.ContainsKey($key)) {
        throw "Unknown SMTP provider '$Name'. Known providers: $(($script:SmtpProviders.Keys | Sort-Object) -join ', '), auto."
    }
    return $script:SmtpProviders[$key]
}

function Set-ConfigValue {
    <# Sets a (possibly nested) value on a configuration object. #>
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Path,
        $Value
    )
    $parts = $Path.Split('.')
    $cur = $Object
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($parts[$i])) { return $false }
            $cur = $cur[$parts[$i]]
        }
        else {
            $p = $cur.PSObject.Properties[$parts[$i]]
            if ($null -eq $p) { return $false }
            $cur = $p.Value
        }
    }
    $leaf = $parts[$parts.Count - 1]
    if ($cur -is [System.Collections.IDictionary]) { $cur[$leaf] = $Value; return $true }
    if ($null -ne $cur.PSObject.Properties[$leaf]) { $cur.$leaf = $Value }
    else { $cur | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value -Force }
    return $true
}

function Resolve-SmtpSettings {
    <#
      Fills the empty fields of an SMTP block from its provider. A field that
      is set explicitly is never overwritten, so a client can still point at
      a relay of its own.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SmtpConfig)

    $username = [string](Get-ConfigValue -Object $SmtpConfig -Path 'username' -Default '')
    $provider = Get-SmtpProvider -Name ([string](Get-ConfigValue -Object $SmtpConfig -Path 'provider' -Default 'auto')) -Username $username

    $hostName = [string](Get-ConfigValue -Object $SmtpConfig -Path 'host' -Default '')
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        [void](Set-ConfigValue -Object $SmtpConfig -Path 'host' -Value $provider.Host)
    }
    $port = [int](Get-ConfigValue -Object $SmtpConfig -Path 'port' -Default 0)
    if ($port -le 0) {
        [void](Set-ConfigValue -Object $SmtpConfig -Path 'port' -Value $provider.Port)
    }
    $encryption = [string](Get-ConfigValue -Object $SmtpConfig -Path 'encryption' -Default '')
    if ([string]::IsNullOrWhiteSpace($encryption)) {
        [void](Set-ConfigValue -Object $SmtpConfig -Path 'encryption' -Value $provider.Encryption)
    }
    $helo = [string](Get-ConfigValue -Object $SmtpConfig -Path 'heloDomain' -Default '')
    if ([string]::IsNullOrWhiteSpace($helo)) {
        if ($username -match '@(.+)$') { $helo = $Matches[1] } else { $helo = $provider.HeloDomain }
        [void](Set-ConfigValue -Object $SmtpConfig -Path 'heloDomain' -Value $helo)
    }
    return $SmtpConfig
}

function Get-SmtpAccountList {
    <#
      Returns every SMTP account the configuration declares.

      A configuration may hold one account directly under "smtp", or a list
      under "smtp.accounts". With several accounts the engine spreads the
      campaign over them and moves on when one stops accepting mail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $smtp = Get-ConfigValue -Object $Config -Path 'smtp'
    if ($null -eq $smtp) { throw 'The configuration has no "smtp" section.' }

    $list = New-Object System.Collections.Generic.List[object]
    $accounts = @(Get-ConfigValue -Object $smtp -Path 'accounts' -Default @())
    if ($accounts.Count -gt 0) {
        $i = 0
        foreach ($a in $accounts) {
            if ($null -eq $a) { continue }
            $i++
            $resolved = Resolve-SmtpSettings -SmtpConfig $a
            $label = [string](Get-ConfigValue -Object $a -Path 'label' -Default ("account $i"))
            [void](Set-ConfigValue -Object $resolved -Path 'label' -Value $label)
            [void]$list.Add($resolved)
        }
    }
    else {
        $resolved = Resolve-SmtpSettings -SmtpConfig $smtp
        $label = [string](Get-ConfigValue -Object $smtp -Path 'label' -Default 'default')
        [void](Set-ConfigValue -Object $resolved -Path 'label' -Value $label)
        [void]$list.Add($resolved)
    }
    if ($list.Count -eq 0) { throw 'No SMTP account is configured.' }
    return $list.ToArray()
}

# ------------------------------------------------------------------- merge --
function ConvertTo-MergeTree {
    <# Turns any configuration object into nested hashtables and arrays. #>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Value.Keys) { $h[[string]$k] = ConvertTo-MergeTree $Value[$k] }
        return $h
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-MergeTree $p.Value }
        return $h
    }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        $arr = @()
        foreach ($item in $Value) { $arr += ,(ConvertTo-MergeTree $item) }
        return ,$arr
    }
    return $Value
}

function Merge-MergeTree {
    <#
      Deep merge. Objects are merged key by key; a list in the override
      replaces the list in the base, because a campaign that defines its own
      creatives must not inherit a half-configured one.
    #>
    param($Base, $Override)

    if ($null -eq $Override) {
        if ($Base -is [object[]]) { return ,$Base }
        return $Base
    }
    if ($Base -is [System.Collections.IDictionary] -and $Override -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
        foreach ($k in $Override.Keys) {
            if ($out.ContainsKey($k)) {
                $out[$k] = Merge-MergeTree -Base $out[$k] -Override $Override[$k]
            }
            else {
                $out[$k] = $Override[$k]
            }
        }
        return $out
    }
    # A list with a single entry has to stay a list. Returning it
    # directly would unroll it into one plain value and the list is lost.
    if ($Override -is [object[]]) { return ,$Override }
    return $Override
}

function ConvertTo-PSObjectTree {
    <# Turns the merged hashtable tree back into plain configuration objects. #>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [PSCustomObject]@{}
        foreach ($k in ($Value.Keys | Sort-Object)) {
            $o | Add-Member -NotePropertyName ([string]$k) -NotePropertyValue (ConvertTo-PSObjectTree $Value[$k])
        }
        return $o
    }
    if ($Value -is [object[]]) {
        $arr = @()
        foreach ($item in $Value) { $arr += ,(ConvertTo-PSObjectTree $item) }
        return ,$arr
    }
    return $Value
}

function Merge-ClientConfig {
    <#
      Applies a client profile on top of the base configuration.
      The profile wins for every key it defines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BaseConfig,
        $Profile
    )

    $override = $null
    if ($null -ne $Profile) {
        $override = ConvertTo-MergeTree $Profile
        if ($override -is [System.Collections.IDictionary]) {
            # id, name and description describe the client; they are not
            # configuration keys and must not end up in the merged config.
            foreach ($k in @('id', 'name', 'description')) {
                if ($override.ContainsKey($k)) { [void]$override.Remove($k) }
            }
        }
    }
    $merged = Merge-MergeTree -Base (ConvertTo-MergeTree $BaseConfig) -Override $override
    return (ConvertTo-PSObjectTree $merged)
}

# ------------------------------------------------------------------ client --
function Get-SafeClientKey {
    <# Turns a client id into something safe to use as a folder name. #>
    param([string]$Value)

    $v = ([string]$Value).Trim()
    if ($v -eq '') { return '' }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $v = $v.Replace([string]$c, '-') }
    $v = $v -replace '[^A-Za-z0-9._-]', '-'
    return $v.Trim('-')
}

function Get-ClientProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Client profile not found: $Path" }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $raw = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Client profile '$full' is empty." }
    $obj = $raw | ConvertFrom-Json
    return [PSCustomObject]@{
        Path      = $full
        Directory = (Split-Path -Parent $full)
        Data      = $obj
        Id        = ([string](Get-ConfigValue -Object $obj -Path 'id' -Default '')).Trim()
        Name      = ([string](Get-ConfigValue -Object $obj -Path 'name' -Default '')).Trim()
    }
}

function Resolve-ClientProfilePath {
    <#
      Finds the profile of a client. A client is either a file path or an id
      that lives in clients/<id>/client.json or clients/<id>.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ClientId = '',
        [string]$ClientPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ClientPath)) {
        $p = $ClientPath
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $ProjectRoot $p }
        if (-not (Test-Path -LiteralPath $p)) { throw "Client profile not found: $p" }
        return (Resolve-Path -LiteralPath $p).ProviderPath
    }
    if ([string]::IsNullOrWhiteSpace($ClientId)) { return '' }

    $key = Get-SafeClientKey -Value $ClientId
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'The client id is empty.' }
    $candidates = @(
        (Join-Path $ProjectRoot "clients\$key\client.json"),
        (Join-Path $ProjectRoot "clients\$key.json")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).ProviderPath }
    }
    throw "No client profile found for '$ClientId'. Looked in: $($candidates -join ', ')"
}

function Get-ClientStateDir {
    <#
      The state directory of a client. Every client gets its own checkpoint and
      its own suppression list, so no client can ever contact an address that
      another client suppressed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ClientId = '',
        [string]$StateDir = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        $p = $StateDir
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $ProjectRoot $p }
        return $p
    }
    $key = Get-SafeClientKey -Value $ClientId
    if ([string]::IsNullOrWhiteSpace($key)) { return (Join-Path $ProjectRoot 'state') }
    return (Join-Path $ProjectRoot "state\$key")
}

function Get-ClientLogDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ClientId = ''
    )
    $key = Get-SafeClientKey -Value $ClientId
    if ([string]::IsNullOrWhiteSpace($key)) { return (Join-Path $ProjectRoot 'logs') }
    return (Join-Path $ProjectRoot "logs\$key")
}

function Resolve-TemplatePath {
    <#
      Resolves a template path. A path next to the client profile wins, then a
      path inside the project, so a client can ship its own message without
      touching the shared templates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ClientDir = '',
        [string]$ProjectRoot = ''
    )

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    if (-not [string]::IsNullOrWhiteSpace($ClientDir)) {
        $c = Join-Path $ClientDir $Path
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).ProviderPath }
    }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $p = Join-Path $ProjectRoot $Path
        if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).ProviderPath }
    }
    return $Path
}

function Resolve-ClientPaths {
    <# Resolves every template path of a merged configuration. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$ClientDir = '',
        [string]$ProjectRoot = ''
    )

    $msg = Get-ConfigValue -Object $Config -Path 'message'
    if ($null -eq $msg) { return }

    foreach ($key in @('templatePath', 'textTemplatePath')) {
        $v = [string](Get-ConfigValue -Object $msg -Path $key -Default '')
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        [void](Set-ConfigValue -Object $msg -Path $key -Value (Resolve-TemplatePath -Path $v -ClientDir $ClientDir -ProjectRoot $ProjectRoot))
    }
    foreach ($v in @(Get-ConfigValue -Object $msg -Path 'variants' -Default @())) {
        if ($null -eq $v) { continue }
        foreach ($key in @('templatePath', 'textTemplatePath')) {
            $val = [string](Get-ConfigValue -Object $v -Path $key -Default '')
            if ([string]::IsNullOrWhiteSpace($val)) { continue }
            [void](Set-ConfigValue -Object $v -Path $key -Value (Resolve-TemplatePath -Path $val -ClientDir $ClientDir -ProjectRoot $ProjectRoot))
        }
    }
}

# --------------------------------------------------------------- recipients --
function Import-RecipientList {
    <#
      Reads a recipient list.

      A CSV keeps every column, so extra columns work as {{placeholders}}.
      A plain text file holds one address per line, optionally followed by a
      comma and a name. Blank lines and lines starting with # are ignored,
      and a duplicate address is only kept once.

      A plain text file is the format for a large list: ten thousand lines
      load in well under a second and cost no more than the CSV path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Recipients file not found: $Path" }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    $rows = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if ($ext -eq '.csv' -or $ext -eq '.tsv') {
        foreach ($r in @(Import-Csv -LiteralPath $Path -Encoding UTF8)) {
            if ($null -eq $r) { continue }
            $email = ([string]$r.email).Trim()
            if ([string]::IsNullOrWhiteSpace($email)) { continue }
            if (-not $seen.Add($email)) { continue }
            [void]$rows.Add($r)
        }
    }
    else {
        foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
            $t = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            if ($t.StartsWith('#')) { continue }
            $sep = $t.IndexOfAny([char[]]@(',', ';', [char]9))
            $email = $t
            $name = ''
            if ($sep -gt 0) {
                $email = $t.Substring(0, $sep).Trim()
                $name = $t.Substring($sep + 1).Trim()
            }
            $email = $email.Trim().Trim('<', '>')
            if ($email -notmatch '^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$') { continue }
            if (-not $seen.Add($email)) { continue }
            [void]$rows.Add([PSCustomObject]@{ email = $email; name = $name })
        }
    }
    return $rows.ToArray()
}

# --------------------------------------------------------------- short link --
function Get-ShortLinkCode {
    <#
      A short, stable code for a tracking link. The same seed always yields
      the same code, so a campaign that is resumed keeps its links.
    #>
    [CmdletBinding()]
    param(
        [string]$Seed = '',
        [int]$Length = 8
    )

    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $raw = Get-Sha256Hex ("mailrotator|$Seed")
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        $idx = [int]$raw[($i * 2)] * 16 + [int]$raw[($i * 2 + 1)]
        [void]$sb.Append($alphabet[$idx % $alphabet.Length])
    }
    return $sb.ToString()
}

# ------------------------------------------------------------------ proxy --
function Resolve-ProxySettings {
    <#
      Fills the empty proxy fields from the proxy family.

      The provider decides the environment variable that holds the password,
      the region parameter and the session lifetime, so the operator only has
      to supply the account, the host, the port and the password.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $proxy = Get-ConfigValue -Object $Config -Path 'proxy'
    if ($null -eq $proxy) { return $null }

    $providerName = [string](Get-ConfigValue -Object $proxy -Path 'provider' -Default '9proxy')
    $spec = Get-ProxyProvider -Name $providerName

    $envName = [string](Get-ConfigValue -Object $proxy -Path 'passwordEnv' -Default '')
    if ([string]::IsNullOrWhiteSpace($envName)) {
        [void](Set-ConfigValue -Object $proxy -Path 'passwordEnv' -Value $spec.PasswordEnv)
    }

    $mins = [int](Get-ConfigValue -Object $proxy -Path 'sessionTimeMinutes' -Default 0)
    if ($mins -le 0) { $mins = [int](Get-ConfigValue -Object $proxy -Path 'stickyMinutes' -Default 0) }
    if ($mins -gt 0) { [void](Set-ConfigValue -Object $proxy -Path 'sessionTimeMinutes' -Value $mins) }

    if (-not [string]::IsNullOrWhiteSpace($spec.Zone)) {
        $zone = [string](Get-ConfigValue -Object $proxy -Path 'zone' -Default '')
        if ([string]::IsNullOrWhiteSpace($zone)) {
            [void](Set-ConfigValue -Object $proxy -Path 'zone' -Value 'custom')
        }
    }

    $sep = [string](Get-ConfigValue -Object $proxy -Path 'paramSeparator' -Default '')
    if ([string]::IsNullOrWhiteSpace($sep)) {
        [void](Set-ConfigValue -Object $proxy -Path 'paramSeparator' -Value '-')
    }

    return $proxy
}
