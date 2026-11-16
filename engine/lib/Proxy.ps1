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
  Proxy transport layer.

  Supports three transports:
    none    - direct TCP to the target (no proxy)
    http    - HTTP CONNECT tunneling (9Proxy "Residential by GB", and the
              local port-forward exposed by the 9Proxy desktop app when it is
              configured as an HTTP proxy)
    socks5  - SOCKS5 CONNECT with optional username/password auth

  Every transport returns a plain NetworkStream that the SMTP layer can then
  upgrade to TLS with SslStream.
#>

function Open-ProxyTunnel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TargetPort,
        [ValidateSet('none', 'http', 'socks5')][string]$Transport = 'none',
        [string]$ProxyHost = '',
        [int]$ProxyPort = 0,
        [string]$ProxyUsername = '',
        [string]$ProxyPassword = '',
        [int]$ConnectTimeoutMs = 20000,
        [int]$HandshakeTimeoutMs = 20000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        # --- phase 1: reach the proxy (or the target directly) ---
        $connectHost = if ($Transport -eq 'none') { $TargetHost } else { $ProxyHost }
        $connectPort = if ($Transport -eq 'none') { $TargetPort } else { $ProxyPort }
        if ([string]::IsNullOrWhiteSpace($connectHost)) { throw 'Proxy host is empty.' }

        $iar = $client.BeginConnect($connectHost, $connectPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($ConnectTimeoutMs, $false)) {
            throw "TCP connect to ${connectHost}:${connectPort} timed out after ${ConnectTimeoutMs}ms."
        }
        try { $client.EndConnect($iar) } catch { throw "TCP connect to ${connectHost}:${connectPort} failed: $($_.Exception.Message)" }

        $stream = $client.GetStream()
        $stream.ReadTimeout = $HandshakeTimeoutMs
        $stream.WriteTimeout = $HandshakeTimeoutMs

        if ($Transport -eq 'none') {
            return [PSCustomObject]@{ Client = $client; Stream = $stream; Transport = 'none' }
        }

        if ($Transport -eq 'http') {
            Invoke-HttpConnectTunnel -Stream $stream -TargetHost $TargetHost -TargetPort $TargetPort `
                -ProxyUsername $ProxyUsername -ProxyPassword $ProxyPassword
        }
        elseif ($Transport -eq 'socks5') {
            Invoke-Socks5Tunnel -Stream $stream -TargetHost $TargetHost -TargetPort $TargetPort `
                -ProxyUsername $ProxyUsername -ProxyPassword $ProxyPassword
        }

        return [PSCustomObject]@{ Client = $client; Stream = $stream; Transport = $Transport }
    }
    catch {
        try { $client.Close() } catch { }
        throw
    }
}

function Invoke-HttpConnectTunnel {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TargetPort,
        [string]$ProxyUsername = '',
        [string]$ProxyPassword = ''
    )

    $target = "${TargetHost}:${TargetPort}"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("CONNECT $target HTTP/1.1`r`n")
    [void]$sb.Append("Host: $target`r`n")
    if (-not [string]::IsNullOrWhiteSpace($ProxyUsername)) {
        $cred = ConvertTo-Base64 "${ProxyUsername}:${ProxyPassword}"
        [void]$sb.Append("Proxy-Authorization: Basic $cred`r`n")
    }
    [void]$sb.Append("Proxy-Connection: Keep-Alive`r`n`r`n")
    $req = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($req, 0, $req.Length)
    $Stream.Flush()

    $reader = New-LineReader -Stream $Stream
    $statusLine = $reader.ReadLine()
    if ($statusLine -notmatch '^\s*HTTP/1\.[01]\s+(\d{3})') {
        throw "Proxy CONNECT returned a malformed status line: '$statusLine'"
    }
    $status = [int]$Matches[1]

    # drain headers
    while ($true) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrEmpty($line)) { break }
    }

    if ($status -ne 200) {
        throw "Proxy CONNECT to $target was refused with HTTP status $status."
    }
}

function Invoke-Socks5Tunnel {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TargetPort,
        [string]$ProxyUsername = '',
        [string]$ProxyPassword = ''
    )

    $hasAuth = -not [string]::IsNullOrWhiteSpace($ProxyUsername)

    # greeting: version 5, offer no-auth and user/pass
    $greet = if ($hasAuth) { [byte[]]@(0x05, 0x02, 0x00, 0x02) } else { [byte[]]@(0x05, 0x01, 0x00) }
    $Stream.Write($greet, 0, $greet.Length)
    $Stream.Flush()

    $resp = New-Object byte[] 2
    Read-Exact -Stream $Stream -Buffer $resp -Count 2 -What 'SOCKS5 greeting response'
    if ($resp[0] -ne 0x05) { throw "SOCKS5 server replied with version 0x$('{0:x2}' -f $resp[0]), expected 0x05." }

    if ($resp[1] -eq 0x02) {
        if (-not $hasAuth) { throw 'SOCKS5 server requested username/password auth but no credentials were configured.' }
        $uBytes = [Text.Encoding]::UTF8.GetBytes($ProxyUsername)
        $pBytes = [Text.Encoding]::UTF8.GetBytes($ProxyPassword)
        $auth = New-Object System.Collections.Generic.List[byte]
        $auth.Add(0x01)
        $auth.Add([byte]$uBytes.Length)
        $auth.AddRange($uBytes)
        $auth.Add([byte]$pBytes.Length)
        $auth.AddRange($pBytes)
        $authArr = $auth.ToArray()
        $Stream.Write($authArr, 0, $authArr.Length)
        $Stream.Flush()
        $aResp = New-Object byte[] 2
        Read-Exact -Stream $Stream -Buffer $aResp -Count 2 -What 'SOCKS5 auth response'
        if ($aResp[1] -ne 0x00) { throw "SOCKS5 username/password authentication failed (status 0x$('{0:x2}' -f $aResp[1]))." }
    }
    elseif ($resp[1] -ne 0x00) {
        throw "SOCKS5 server refused all offered authentication methods (status 0x$('{0:x2}' -f $resp[1]))."
    }

    # CONNECT with domain-name addressing so DNS resolution happens at the exit node
    $hostBytes = [Text.Encoding]::ASCII.GetBytes($TargetHost)
    $req = New-Object System.Collections.Generic.List[byte]
    $req.Add(0x05); $req.Add(0x01); $req.Add(0x00); $req.Add(0x03)
    $req.Add([byte]$hostBytes.Length)
    $req.AddRange($hostBytes)
    $req.Add([byte](($TargetPort -shr 8) -band 0xFF))
    $req.Add([byte]($TargetPort -band 0xFF))
    $reqArr = $req.ToArray()
    $Stream.Write($reqArr, 0, $reqArr.Length)
    $Stream.Flush()

    $head = New-Object byte[] 4
    Read-Exact -Stream $Stream -Buffer $head -Count 4 -What 'SOCKS5 connect response'
    if ($head[0] -ne 0x05) { throw 'Invalid SOCKS5 reply version.' }
    if ($head[1] -ne 0x00) {
        $codes = @{
            0x01 = 'general SOCKS server failure'
            0x02 = 'connection not allowed by ruleset'
            0x03 = 'network unreachable'
            0x04 = 'host unreachable'
            0x05 = 'connection refused'
            0x06 = 'TTL expired'
            0x07 = 'command not supported'
            0x08 = 'address type not supported'
        }
        $why = if ($codes.ContainsKey([int]$head[1])) { $codes[[int]$head[1]] } else { 'unknown error' }
        throw "SOCKS5 CONNECT to ${TargetHost}:${TargetPort} failed: $why (0x$('{0:x2}' -f $head[1]))."
    }
    $addrType = $head[3]
    switch ($addrType) {
        0x01 { $skip = 4 }
        0x04 { $skip = 16 }
        0x03 {
            $l = New-Object byte[] 1
            Read-Exact -Stream $Stream -Buffer $l -Count 1 -What 'SOCKS5 addr length'
            $skip = $l[0]
        }
        default { throw "SOCKS5 reply used unsupported address type 0x$('{0:x2}' -f $addrType)." }
    }
    $skipBuf = New-Object byte[] ($skip + 2)
    Read-Exact -Stream $Stream -Buffer $skipBuf -Count ($skip + 2) -What 'SOCKS5 bound address'
}

function Read-Exact {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][int]$Count,
        [string]$What = 'data'
    )
    $read = 0
    while ($read -lt $Count) {
        $n = $Stream.Read($Buffer, $read, $Count - $read)
        if ($n -le 0) { throw "Connection closed while reading $What." }
        $read += $n
    }
}

function New-TlsStreamOver {
    <# Upgrades an established tunnel into TLS. Returns the SslStream. #>
    param(
        [Parameter(Mandatory)][System.IO.Stream]$InnerStream,
        [Parameter(Mandatory)][string]$TargetHost,
        [switch]$AllowUntrustedCertificate
    )
    $validate = { param($sender, $cert, $chain, $errors) return $true }
    $ssl = New-Object System.Net.Security.SslStream($InnerStream, $false, $validate)
    $ssl.AuthenticateAsClient($TargetHost)
    return $ssl
}

function Get-EgressIpViaProxy {
    <#
      Resolves the public IP seen by a given proxy endpoint by performing an
      HTTPS GET to an IP echo service through the same tunnel used for SMTP.
      Returns the IP string, or $null when the check could not be performed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TargetPort,
        [ValidateSet('none', 'http', 'socks5')][string]$Transport = 'none',
        [string]$ProxyHost = '',
        [int]$ProxyPort = 0,
        [string]$ProxyUsername = '',
        [string]$ProxyPassword = '',
        [string]$Path = '/',
        [int]$TimeoutMs = 20000
    )

    $tunnel = $null
    try {
        $tunnel = Open-ProxyTunnel -TargetHost $TargetHost -TargetPort $TargetPort -Transport $Transport `
            -ProxyHost $ProxyHost -ProxyPort $ProxyPort -ProxyUsername $ProxyUsername `
            -ProxyPassword $ProxyPassword -ConnectTimeoutMs $TimeoutMs -HandshakeTimeoutMs $TimeoutMs

        $ssl = New-TlsStreamOver -InnerStream $tunnel.Stream -TargetHost $TargetHost
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.WriteTimeout = $TimeoutMs

        $req = "GET $Path HTTP/1.1`r`nHost: ${TargetHost}`r`nUser-Agent: mailrotator/1.0`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($bytes, 0, $bytes.Length)
        $ssl.Flush()

        $reader = New-LineReader -Stream $ssl
        $status = $reader.ReadLine()
        $body = New-Object System.Text.StringBuilder
        $inBody = $false
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if (-not $inBody) {
                if ([string]::IsNullOrEmpty($line)) { $inBody = $true }
                continue
            }
            [void]$body.AppendLine($line)
            if ($body.Length -gt 4096) { break }
        }
        $text = $body.ToString().Trim()
        if ($text -match '^\d{1,3}(\.\d{1,3}){3}$') { return $text }
        return $null
    }
    catch {
        return $null
    }
    finally {
        if ($tunnel) {
            try { $tunnel.Stream.Dispose() } catch { }
            try { $tunnel.Client.Close() } catch { }
        }
    }
}
