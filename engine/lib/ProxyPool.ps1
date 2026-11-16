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
  Proxy pool and IP rotation.

  Three proxy families are supported. The account, the host, the port and the
  password always come from the operator; only the shape of the username and
  the way a new exit IP is requested differ between them.

  9Proxy - "Residential Proxies by GB" (gateway mode). One fixed host:port.
      The exit IP is chosen by the username, so a new session token means a
      new IP:
          {account}-country-{country}-st-{state}-city-{city}-isp-{isp}-ssid-{session}

  711Proxy - "Unlimited Proxies". The same idea with 711Proxy's own
      parameter names. The region is a two letter uppercase code, the session
      token is wrapped in brackets, and the lifetime of the IP is expressed in
      minutes:
          {account}-zone-custom-region-{REGION}-st-{state}-city-{city}-sessTime-{minutes}-session-({session})

  Custom - anything else. The operator writes the whole username pattern and
      the engine fills the tokens:
          {usernameTemplate} with {country} {state} {city} {isp} {session} {sessionTime}

  Four deployment shapes are supported:

    gateway - one fixed host:port, the exit IP is rotated by the session
              token that is written into the username.
    ports   - one host and a list of ports, where every port is a different
              exit IP (711Proxy "By Port").
    local   - the 9Proxy desktop application forwards a residential IP to
              127.0.0.1:<port>; the engine rotates between those ports.
    none    - no proxy at all.
#>

# ---------------------------------------------------------- provider table --
$script:ProxyProviderSpecs = @{
    '9proxy' = @{
        Label                = '9Proxy'
        PasswordEnv          = 'NINEPROXY_PASSWORD'
        Country              = 'country'
        CountryUpper         = $false
        State                = 'st'
        City                 = 'city'
        Isp                  = 'isp'
        Zone                 = ''
        Sticky               = 'sst'
        Session              = 'ssid'
        SessionParenthesised = $false
        Order                = @('country', 'state', 'city', 'isp', 'sticky', 'session')
    }
    '711proxy' = @{
        Label                = '711Proxy'
        PasswordEnv          = 'SEVEN11PROXY_PASSWORD'
        Country              = 'region'
        CountryUpper         = $true
        State                = 'st'
        City                 = 'city'
        Isp                  = ''
        Zone                 = 'zone'
        Sticky               = 'sessTime'
        Session              = 'session'
        SessionParenthesised = $true
        Order                = @('zone', 'country', 'state', 'city', 'sticky', 'session')
    }
    'custom' = @{
        Label                = 'Custom'
        PasswordEnv          = 'PROXY_PASSWORD'
        Country              = 'country'
        CountryUpper         = $false
        State                = 'st'
        City                 = 'city'
        Isp                  = 'isp'
        Zone                 = ''
        Sticky               = 'sst'
        Session              = 'ssid'
        SessionParenthesised = $false
        Order                = @('country', 'state', 'city', 'isp', 'sticky', 'session')
    }
}

function Get-ProxyProvider {
    <#
      The specification of a proxy family: how the username is built and which
      environment variable holds the password.
    #>
    [CmdletBinding()]
    param([string]$Name = '9proxy')

    $key = ([string]$Name).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($key)) { $key = '9proxy' }
    if (-not $script:ProxyProviderSpecs.ContainsKey($key)) {
        throw "Unknown proxy provider '$Name'. Known providers: $(($script:ProxyProviderSpecs.Keys | Sort-Object) -join ', ')."
    }
    return $script:ProxyProviderSpecs[$key]
}

function New-ProxyUsername {
    <#
      Builds the username that decides the exit IP.

      For a custom provider the template is used as written and the tokens are
      filled in. For the known families the account name is the base and the
      targeting parameters are appended in the order the family expects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Pool,
        [Parameter(Mandatory)][string]$SessionId,
        [switch]$NoSession
    )

    $spec = Get-ProxyProvider -Name $Pool.Provider
    $base = ([string]$Pool.UsernameTemplate).Trim()
    if ($base -eq '') { $base = 'subaccount' }
    $sep = [string]$Pool.ParamSeparator
    if ([string]::IsNullOrWhiteSpace($sep)) { $sep = '-' }

    # A custom pattern is used verbatim, so any other service can be driven
    # without touching the engine.
    if ($Pool.Provider -eq 'custom' -and $base.Contains('{')) {
        $map = [ordered]@{
            '{country}'     = [string]$Pool.Country
            '{state}'       = [string]$Pool.State
            '{city}'        = [string]$Pool.City
            '{isp}'         = [string]$Pool.Isp
            '{session}'     = $SessionId
            '{sessionTime}' = [string]$Pool.SessionTimeMinutes
        }
        $out = $base
        foreach ($k in $map.Keys) { $out = $out.Replace($k, $map[$k]) }
        return $out
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($key in $spec.Order) {
        switch ($key) {
            'zone' {
                if (-not [string]::IsNullOrWhiteSpace($spec.Zone) -and -not [string]::IsNullOrWhiteSpace([string]$Pool.Zone)) {
                    [void]$parts.Add(('{0}-{1}' -f $spec.Zone, [string]$Pool.Zone))
                }
            }
            'country' {
                $v = ([string]$Pool.Country).Trim()
                if (-not [string]::IsNullOrWhiteSpace($v)) {
                    if ($spec.CountryUpper) { $v = $v.ToUpperInvariant() }
                    [void]$parts.Add(('{0}-{1}' -f $spec.Country, $v))
                }
            }
            'state' {
                $v = ([string]$Pool.State).Trim()
                if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$parts.Add(('{0}-{1}' -f $spec.State, $v)) }
            }
            'city' {
                $v = ([string]$Pool.City).Trim()
                if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$parts.Add(('{0}-{1}' -f $spec.City, $v)) }
            }
            'isp' {
                $v = ([string]$Pool.Isp).Trim()
                if (-not [string]::IsNullOrWhiteSpace($spec.Isp) -and -not [string]::IsNullOrWhiteSpace($v)) {
                    [void]$parts.Add(('{0}-{1}' -f $spec.Isp, $v))
                }
            }
            'sticky' {
                $mins = [int]$Pool.SessionTimeMinutes
                if ($mins -gt 0 -and -not [string]::IsNullOrWhiteSpace($spec.Sticky)) {
                    [void]$parts.Add(('{0}-{1}' -f $spec.Sticky, $mins))
                }
            }
            'session' {
                if ($NoSession) { break }
                $v = $SessionId
                if ($spec.SessionParenthesised) { $v = '(' + $v + ')' }
                [void]$parts.Add(('{0}-{1}' -f $spec.Session, $v))
            }
        }
    }

    $all = New-Object System.Collections.Generic.List[string]
    [void]$all.Add($base)
    foreach ($p in $parts) { [void]$all.Add($p) }
    return ($all -join $sep)
}

function New-ProxyPool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [string]$Provider = '9proxy',
        [string]$HostName = '',
        [int]$Port = 0,
        [string]$UsernameTemplate = '',
        [string]$Password = '',
        [scriptblock]$PasswordProvider = $null,
        [ValidateSet('http', 'socks5')][string]$Transport = 'http',
        [int[]]$LocalPorts = @(),
        [string]$Country = '',
        [string]$State = '',
        [string]$City = '',
        [string]$Isp = '',
        [string]$Zone = '',
        [int]$SessionTimeMinutes = 0,
        [string]$ParamSeparator = '-',
        [int]$RotationEvery = 150,
        [string]$EgressCheckHost = 'api.ipify.org',
        [int]$EgressCheckPort = 443,
        [string]$EgressCheckPath = '/',
        [switch]$SkipEgressCheck
    )

    $pool = [PSCustomObject]@{
        Mode                  = $Mode
        Provider              = $Provider
        HostName              = $HostName
        Port                  = $Port
        UsernameTemplate      = $UsernameTemplate
        Password              = $Password
        PasswordProvider      = $PasswordProvider
        Transport             = $Transport
        LocalPorts            = $LocalPorts
        Country               = $Country
        State                 = $State
        City                  = $City
        Isp                   = $Isp
        Zone                  = $Zone
        SessionTimeMinutes    = $SessionTimeMinutes
        ParamSeparator        = $ParamSeparator
        RotationEvery         = $RotationEvery
        EgressCheckHost       = $EgressCheckHost
        EgressCheckPort       = $EgressCheckPort
        EgressCheckPath       = $EgressCheckPath
        SkipEgressCheck       = [bool]$SkipEgressCheck

        CurrentIndex      = -1
        CurrentEndpoint   = $null
        CurrentEgressIp   = $null
        CurrentSessionId  = ''
        MessagesSinceRotate = 0
        RotationCount     = 0
        SessionCounter    = 0
        History           = New-Object System.Collections.Generic.List[object]
    }
    return $pool
}

function Get-ProxyEndpoint {
    <#
      Returns the endpoint description to use for the next connection.
      In gateway mode a fresh session token is minted so the gateway selects
      a new exit IP. In ports and local mode the next port is selected.
    #>
    param([Parameter(Mandatory)]$Pool)

    switch ($Pool.Mode) {
        'gateway' {
            $Pool.SessionCounter++
            $session = 'mail' + (Get-Random -Minimum 100000 -Maximum 999999)
            $password = if ($Pool.PasswordProvider) { [string](& $Pool.PasswordProvider) }
                        else { [string]$Pool.Password }
            $username = New-ProxyUsername -Pool $Pool -SessionId $session
            return [PSCustomObject]@{
                Kind        = 'gateway'
                Transport   = $Pool.Transport
                ProxyHost   = $Pool.HostName
                ProxyPort   = $Pool.Port
                Username    = $username
                Password    = $password
                SessionId   = $session
                Label       = "$($Pool.HostName):$($Pool.Port) [$username]"
            }
        }
        'ports' {
            if ($Pool.LocalPorts.Count -eq 0) { throw 'Proxy mode "ports" requires a list of ports.' }
            $Pool.CurrentIndex = ($Pool.CurrentIndex + 1) % $Pool.LocalPorts.Count
            $p = $Pool.LocalPorts[$Pool.CurrentIndex]
            $password = if ($Pool.PasswordProvider) { [string](& $Pool.PasswordProvider) }
                        else { [string]$Pool.Password }
            $username = New-ProxyUsername -Pool $Pool -SessionId ('port' + $p) -NoSession
            return [PSCustomObject]@{
                Kind        = 'ports'
                Transport   = $Pool.Transport
                ProxyHost   = $Pool.HostName
                ProxyPort   = $p
                Username    = $username
                Password    = $password
                SessionId   = "port$p"
                Label       = "$($Pool.HostName):$p [$username]"
            }
        }
        'local' {
            if ($Pool.LocalPorts.Count -eq 0) { throw 'Proxy mode "local" requires at least one forwarded port.' }
            $Pool.CurrentIndex = ($Pool.CurrentIndex + 1) % $Pool.LocalPorts.Count
            $p = $Pool.LocalPorts[$Pool.CurrentIndex]
            return [PSCustomObject]@{
                Kind        = 'local'
                Transport   = $Pool.Transport
                ProxyHost   = '127.0.0.1'
                ProxyPort   = $p
                Username    = ''
                Password    = ''
                SessionId   = "port$p"
                Label       = "127.0.0.1:$p"
            }
        }
        'none' {
            return [PSCustomObject]@{
                Kind        = 'none'
                Transport   = 'none'
                ProxyHost   = ''
                ProxyPort   = 0
                Username    = ''
                Password    = ''
                SessionId   = 'direct'
                Label       = 'direct (no proxy)'
            }
        }
        default {
            throw "Unknown proxy mode '$($Pool.Mode)'. Use gateway, ports, local or none."
        }
    }
}

function Get-EgressIp {
    <# Resolves the public IP for an endpoint through that endpoint's tunnel. #>
    param(
        [Parameter(Mandatory)]$Pool,
        [Parameter(Mandatory)]$Endpoint
    )
    if ($Pool.SkipEgressCheck) { return $null }
    if ($Endpoint.Kind -eq 'none') {
        try {
            $r = Invoke-WebRequest -Uri "https://$($Pool.EgressCheckHost)$($Pool.EgressCheckPath)" `
                -UseBasicParsing -TimeoutSec 15
            return ($r.Content).Trim()
        }
        catch { return $null }
    }
    return (Get-EgressIpViaProxy -TargetHost $Pool.EgressCheckHost -TargetPort $Pool.EgressCheckPort `
        -Path $Pool.EgressCheckPath -Transport $Endpoint.Transport `
        -ProxyHost $Endpoint.ProxyHost -ProxyPort $Endpoint.ProxyPort `
        -ProxyUsername $Endpoint.Username -ProxyPassword $Endpoint.Password)
}

function Get-PoolEgressLabel {
    <#
      Attribution key for a message sent on the current endpoint.

      Prefers the observed egress IP. When detection failed or was skipped the
      IP is unknown, so the session id is used instead. Without this fallback
      every message would be filed under an empty key and the per-IP counters
      in the run report would silently merge distinct senders.
    #>
    param([Parameter(Mandatory)]$Pool)
    if (-not [string]::IsNullOrWhiteSpace([string]$Pool.CurrentEgressIp)) {
        return [string]$Pool.CurrentEgressIp
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Pool.CurrentSessionId)) {
        return "session:$($Pool.CurrentSessionId)"
    }
    return 'unknown'
}

function Add-ProxyMessage {
    <#
      Records that one message was sent on the current endpoint. The rotation
      counter is what drives the "rotate every N messages" policy, so it must
      be incremented for every delivered message.
    #>
    param([Parameter(Mandatory)]$Pool)
    $Pool.MessagesSinceRotate++
    return $Pool.MessagesSinceRotate
}

function Update-ProxyRotation {
    <#
      Rotation policy: after RotationEvery messages have been sent on the
      current endpoint, the next call rotates to a different exit IP.
      Returns $true when a rotation actually happened.
    #>
    param([Parameter(Mandatory)]$Pool)

    if ($Pool.RotationEvery -le 0) { return $false }
    if ($Pool.MessagesSinceRotate -lt $Pool.RotationEvery) { return $false }

    $old = $Pool.CurrentEgressIp
    $ep = Get-ProxyEndpoint -Pool $Pool
    $ip = Get-EgressIp -Pool $Pool -Endpoint $ep
    $Pool.CurrentEndpoint = $ep
    $Pool.CurrentEgressIp = $ip
    $Pool.CurrentSessionId = $ep.SessionId
    $Pool.MessagesSinceRotate = 0
    $Pool.RotationCount++

    $Pool.History.Add([PSCustomObject]@{
        rotationIndex = $Pool.RotationCount
        sessionId     = $ep.SessionId
        endpoint      = $ep.Label
        egressIp      = $ip
        previousIp    = $old
        rotatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    })
    return $true
}

function Initialize-ProxyPool {
    <# Acquires the first endpoint and records its egress IP. #>
    param([Parameter(Mandatory)]$Pool)
    $ep = Get-ProxyEndpoint -Pool $Pool
    $ip = Get-EgressIp -Pool $Pool -Endpoint $ep
    $Pool.CurrentEndpoint = $ep
    $Pool.CurrentEgressIp = $ip
    $Pool.CurrentSessionId = $ep.SessionId
    $Pool.MessagesSinceRotate = 0
    $Pool.RotationCount = 1
    $Pool.History.Add([PSCustomObject]@{
        rotationIndex = 1
        sessionId = $ep.SessionId
        endpoint = $ep.Label
        egressIp = $ip
        previousIp = $null
        rotatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
    return $ep
}

function Get-CurrentEndpoint {
    param([Parameter(Mandatory)]$Pool)
    if (-not $Pool.CurrentEndpoint) { return (Initialize-ProxyPool -Pool $Pool) }
    return $Pool.CurrentEndpoint
}
