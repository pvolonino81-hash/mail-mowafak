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
  Local fake SMTP server used to verify the sending pipeline end to end
  without contacting a real mail server.

  It speaks just enough SMTP for the client: banner, EHLO, AUTH LOGIN,
  MAIL FROM, RCPT TO, DATA, QUIT. A client that hangs up early is handled
  without taking the listener down.

  Every accepted message is appended to a JSONL log so the test can assert on
  how many messages arrived and from which envelope sender.
#>
param(
    [int]$Port = 2525,
    [string]$LogPath = "$env:TEMP\fake-smtp.jsonl",
    [string]$Password = 'testpass',
    [string]$StopFilePath = ''
)

$ErrorActionPreference = 'Continue'
$script:count = 0

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Fake SMTP listening on 127.0.0.1:$Port (log: $LogPath)"

try {
    while ($true) {
        # Cooperative shutdown: the test drops a stop file and the accept loop
        # notices it on the next connection.
        if ($StopFilePath -and (Test-Path -LiteralPath $StopFilePath)) {
            Write-Host 'Fake SMTP stopping (stop file detected).'
            break
        }

        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.AutoFlush = $true
            $writer.NewLine = "`r`n"

            $authed = $false
            $from = ''
            $rcpt = New-Object System.Collections.ArrayList

            $writer.WriteLine('220 fake.local ESMTP ready')

            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $upper = $line.ToUpperInvariant()

                if ($upper.StartsWith('EHLO') -or $upper.StartsWith('HELO')) {
                    $writer.WriteLine('250-fake.local')
                    $writer.WriteLine('250-AUTH LOGIN PLAIN')
                    $writer.WriteLine('250-8BITMIME')
                    $writer.WriteLine('250 SIZE 104857600')
                }
                elseif ($upper.StartsWith('AUTH LOGIN')) {
                    $writer.WriteLine('334 VXNlcm5hbWU6')
                    $null = $reader.ReadLine()
                    $writer.WriteLine('334 UGFzc3dvcmQ6')
                    $p = $reader.ReadLine()
                    if ($null -eq $p) { break }
                    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
                    if ($decoded -eq $Password) { $authed = $true; $writer.WriteLine('235 2.7.0 Authentication successful') }
                    else { $writer.WriteLine('535 5.7.8 Authentication credentials invalid') }
                }
                elseif ($upper.StartsWith('MAIL FROM')) {
                    if (-not $authed) { $writer.WriteLine('530 5.7.0 Authentication required') }
                    elseif ($from -ne '') { $writer.WriteLine('503 5.5.1 Error: nested MAIL command') }
                    else {
                        $from = ($line -replace '(?i)^MAIL FROM:\s*<', '' -replace '>.*$', '')
                        $writer.WriteLine('250 2.1.0 Ok')
                    }
                }
                elseif ($upper.StartsWith('RCPT TO')) {
                    if (-not $authed) { $writer.WriteLine('530 5.7.0 Authentication required') }
                    else {
                        [void]$rcpt.Add(($line -replace '(?i)^RCPT TO:\s*<', '' -replace '>.*$', ''))
                        $writer.WriteLine('250 2.1.5 Ok')
                    }
                }
                elseif ($upper.StartsWith('DATA')) {
                    if (-not $authed) { $writer.WriteLine('530 5.7.0 Authentication required') }
                    else {
                        $writer.WriteLine('354 End data with <CR><LF>.<CR><LF>')
                        $body = New-Object System.Text.StringBuilder
                        while ($true) {
                            $l = $reader.ReadLine()
                            if ($null -eq $l) { break }
                            if ($l -eq '.') { break }
                            [void]$body.AppendLine($l)
                        }
                        $script:count++
                        $rec = [ordered]@{
                            n = $script:count
                            from = $from
                            rcpt = @($rcpt)
                            bytes = $body.Length
                        }
                        Add-Content -LiteralPath $LogPath -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8
                        $writer.WriteLine('250 2.0.0 Ok: queued')
                        $from = ''
                        $rcpt = New-Object System.Collections.ArrayList
                    }
                }
                elseif ($upper.StartsWith('RSET')) { $from = ''; $rcpt = New-Object System.Collections.ArrayList; $writer.WriteLine('250 2.0.0 Ok') }
                elseif ($upper.StartsWith('QUIT')) { $writer.WriteLine('221 2.0.0 Bye'); break }
                elseif ($upper.StartsWith('STARTTLS')) { $writer.WriteLine('454 4.7.0 TLS not available in this test server') }
                else { $writer.WriteLine('250 2.0.0 Ok') }
            }
        }
        catch {
            # a client hanging up mid-conversation must not stop the listener
            Write-Host "  (client connection ended: $($_.Exception.Message))"
        }
        finally {
            try { if ($writer) { $writer.Close() } } catch { }
            try { if ($reader) { $reader.Close() } } catch { }
            try { if ($client) { $client.Close() } } catch { }
        }
    }
}
finally {
    try { $listener.Stop() } catch { }
}
