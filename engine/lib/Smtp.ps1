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
  SMTP client that speaks directly over a proxy tunnel.

  Behavior is matched to what mail.optonline.net actually advertises
  (verified against the live host):
      250-AUTH LOGIN PLAIN
      250-STARTTLS
      250-8BITMIME
      250-SIZE 104857600
      250-DSN

  Two rules the live server enforces and that this client respects:
    1. MAIL FROM is only accepted after AUTH has succeeded.
    2. The envelope sender must match the authenticated account, otherwise the
       server answers 553 "does not match authenticated name".
#>

function New-SmtpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [string]$HeloDomain = 'localhost',
        [ValidateSet('starttls', 'ssl', 'none')][string]$Encryption = 'starttls',
        [ValidateSet('none', 'http', 'socks5')][string]$Transport = 'none',
        [string]$ProxyHost = '',
        [int]$ProxyPort = 0,
        [string]$ProxyUsername = '',
        [string]$ProxyPassword = '',
        [int]$TimeoutMs = 30000
    )

    $tunnel = $null
    $ssl = $null
    try {
        if ($Encryption -eq 'ssl') {
            # implicit TLS: the tunnel is already the TLS carrier
            $tunnel = Open-ProxyTunnel -TargetHost $HostName -TargetPort $Port -Transport $Transport `
                -ProxyHost $ProxyHost -ProxyPort $ProxyPort -ProxyUsername $ProxyUsername `
                -ProxyPassword $ProxyPassword -ConnectTimeoutMs $TimeoutMs -HandshakeTimeoutMs $TimeoutMs
            $ssl = New-TlsStreamOver -InnerStream $tunnel.Stream -TargetHost $HostName
            $ssl.ReadTimeout = $TimeoutMs
            $ssl.WriteTimeout = $TimeoutMs
            $stream = $ssl
        }
        else {
            $tunnel = Open-ProxyTunnel -TargetHost $HostName -TargetPort $Port -Transport $Transport `
                -ProxyHost $ProxyHost -ProxyPort $ProxyPort -ProxyUsername $ProxyUsername `
                -ProxyPassword $ProxyPassword -ConnectTimeoutMs $TimeoutMs -HandshakeTimeoutMs $TimeoutMs
            $stream = $tunnel.Stream
            $stream.ReadTimeout = $TimeoutMs
            $stream.WriteTimeout = $TimeoutMs
        }

        $reader = New-LineReader -Stream $stream
        $banner = Read-SmtpReply -Reader $reader
        if ($banner.Code -ne 220) { throw "SMTP banner was not 220: $($banner.Text)" }

        $ehlo = Send-SmtpCommand -Reader $reader -Stream $stream -Command "EHLO $HeloDomain"

        if ($Encryption -eq 'starttls') {
            if ($ehlo.Code -ne 250) { throw "EHLO failed with $($ehlo.Code): $($ehlo.Text)" }
            if (-not $ehlo.Capabilities.ContainsKey('STARTTLS')) {
                throw 'Server did not advertise STARTTLS, so it cannot be used for an encrypted submission.'
            }
            $tls = Send-SmtpCommand -Reader $reader -Stream $stream -Command 'STARTTLS'
            if ($tls.Code -ne 220) { throw "STARTTLS was refused with $($tls.Code): $($tls.Text)" }

            # nothing may be buffered before the TLS handshake
            if ($reader.PendingBytes() -ne 0) {
                throw 'Server sent unexpected data before the TLS handshake; refusing to continue.'
            }

            $ssl = New-TlsStreamOver -InnerStream $tunnel.Stream -TargetHost $HostName
            $ssl.ReadTimeout = $TimeoutMs
            $ssl.WriteTimeout = $TimeoutMs
            $stream = $ssl
            $reader = New-LineReader -Stream $stream
            $ehlo = Send-SmtpCommand -Reader $reader -Stream $stream -Command "EHLO $HeloDomain"
        }

        if ($ehlo.Code -ne 250) { throw "EHLO failed with $($ehlo.Code): $($ehlo.Text)" }

        # --- authenticate (required before MAIL FROM on this relay) ---
        $auth = Send-SmtpCommand -Reader $reader -Stream $stream -Command 'AUTH LOGIN'
        if ($auth.Code -eq 334) {
            $u = Send-SmtpCommand -Reader $reader -Stream $stream -Command (ConvertTo-Base64 $Username)
            if ($u.Code -eq 334) {
                $p = Send-SmtpCommand -Reader $reader -Stream $stream -Command (ConvertTo-Base64 $Password)
                if ($p.Code -ne 235) { throw "SMTP AUTH LOGIN failed with $($p.Code): $($p.Text)" }
            }
            elseif ($u.Code -ne 235) { throw "SMTP AUTH LOGIN (username) failed with $($u.Code): $($u.Text)" }
        }
        elseif ($auth.Code -ne 235) {
            throw "Server refused AUTH LOGIN with $($auth.Code): $($auth.Text)"
        }

        return [PSCustomObject]@{
            HostName        = $HostName
            Port            = $Port
            Username        = $Username
            HeloDomain      = $HeloDomain
            Transport       = $Transport
            ProxyHost       = $ProxyHost
            ProxyPort       = $ProxyPort
            ProxyUsername   = $ProxyUsername
            ProxyPassword   = $ProxyPassword
            Encryption      = $Encryption
            Capabilities    = $ehlo.Capabilities
            Stream          = $stream
            Reader          = $reader
            Tunnel          = $tunnel
            TlsStream       = $ssl
            EnvelopeSender  = ''
        }
    }
    catch {
        if ($tunnel) {
            try { $tunnel.Client.Close() } catch { }
        }
        throw
    }
}

function Send-SmtpCommand {
    param(
        [Parameter(Mandatory)]$Reader,
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][string]$Command
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Command + "`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
    return (Read-SmtpReply -Reader $Reader)
}

function Read-SmtpReply {
    <#
      Reads one SMTP reply. Handles multi-line (250-...) replies and returns an
      object with the numeric code, the joined text and the parsed capability map.
    #>
    param([Parameter(Mandatory)]$Reader)

    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line) { throw 'SMTP connection closed while awaiting a reply.' }
        $lines.Add($line)
        if ($line.Length -ge 4 -and $line[3] -eq '-') { continue }
        break
    }

    $first = $lines[0]
    $code = 0
    if ($first -match '^(\d{3})') { $code = [int]$Matches[1] } else { $code = -1 }
    $text = ($lines | ForEach-Object { if ($_.Length -gt 4) { $_.Substring(4) } else { '' } }) -join "`n"

    $caps = @{}
    foreach ($l in $lines) {
        if ($l.Length -gt 4) {
            $cap = $l.Substring(4)
            $eq = $cap.IndexOf('=')
            if ($eq -gt 0) { $caps[$cap.Substring(0, $eq).ToUpperInvariant()] = $cap.Substring($eq + 1) }
            else { $caps[$cap.ToUpperInvariant()] = $true }
        }
    }

    return [PSCustomObject]@{ Code = $code; Text = $text; Lines = $lines.ToArray(); Capabilities = $caps }
}

function Send-SmtpMessage {
    <#
      Sends one message to one recipient through an authenticated session.
      Returns a result object; never throws for per-recipient SMTP failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$EnvelopeFrom,
        [Parameter(Mandatory)][string]$EnvelopeTo,
        [Parameter(Mandatory)][string]$RawMessage,
        [switch]$AllowEightBit
    )

    $reader = $Session.Reader
    $stream = $Session.Stream
    $result = [PSCustomObject]@{
        Recipient = $EnvelopeTo
        Sent      = $false
        Code      = 0
        Message   = ''
        Stage     = ''
    }

    try {
        $fromAddr = $EnvelopeFrom -replace '^.*<', '' -replace '>.*$', ''
        $toAddr = $EnvelopeTo -replace '^.*<', '' -replace '>.*$', ''

        $cmd = "MAIL FROM:<$fromAddr>"
        if ($Session.Capabilities.ContainsKey('SIZE')) {
            $cmd += " SIZE=$([Text.Encoding]::UTF8.GetByteCount($RawMessage))"
        }
        if ($AllowEightBit -and $Session.Capabilities.ContainsKey('8BITMIME')) {
            $cmd += ' BODY=8BITMIME'
        }
        $r = Send-SmtpCommand -Reader $reader -Stream $stream -Command $cmd
        $result.Stage = 'MAIL FROM'
        if ($r.Code -ne 250) {
            $result.Code = $r.Code; $result.Message = $r.Text
            return $result
        }

        $r = Send-SmtpCommand -Reader $reader -Stream $stream -Command "RCPT TO:<$toAddr>"
        $result.Stage = 'RCPT TO'
        if ($r.Code -ne 250 -and $r.Code -ne 251) {
            $result.Code = $r.Code; $result.Message = $r.Text
            Send-SmtpCommand -Reader $reader -Stream $stream -Command 'RSET' | Out-Null
            return $result
        }

        $r = Send-SmtpCommand -Reader $reader -Stream $stream -Command 'DATA'
        $result.Stage = 'DATA'
        if ($r.Code -ne 354) {
            $result.Code = $r.Code; $result.Message = $r.Text
            Send-SmtpCommand -Reader $reader -Stream $stream -Command 'RSET' | Out-Null
            return $result
        }

        # dot-stuffing + CRLF normalization
        $body = ConvertTo-CrlfText $RawMessage
        $body = $body -replace '(?m)^\.', '..'
        if (-not $body.EndsWith("`r`n")) { $body += "`r`n" }
        $payload = [Text.Encoding]::UTF8.GetBytes($body + ".`r`n")
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()

        $r = Read-SmtpReply -Reader $reader
        $result.Stage = 'DATA payload'
        $result.Code = $r.Code
        $result.Message = $r.Text
        $result.Sent = ($r.Code -eq 250)
        return $result
    }
    catch {
        $result.Stage = 'exception'
        $result.Code = -1
        $result.Message = $_.Exception.Message
        return $result
    }
}

function Close-SmtpSession {
    param([Parameter(Mandatory)]$Session)
    try {
        if ($Session.Stream -and $Session.Stream.CanWrite) {
            $bytes = [Text.Encoding]::ASCII.GetBytes("QUIT`r`n")
            $Session.Stream.Write($bytes, 0, $bytes.Length)
            $Session.Stream.Flush()
        }
    }
    catch { }
    finally {
        try { if ($Session.Tunnel) { $Session.Tunnel.Client.Close() } } catch { }
        try { if ($Session.TlsStream) { $Session.TlsStream.Dispose() } } catch { }
    }
}
