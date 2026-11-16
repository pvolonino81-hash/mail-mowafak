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
  Tiny local HTTP server used by the integration test so link reachability
  checks have something real to talk to.

  Answers 200 to any request and appends the requested path to a log, which
  lets the test prove that a given creative's link was actually used.
#>
param(
    [int]$Port = 2528,
    [string]$LogPath = "$env:TEMP\fake-http.log"
)

$ErrorActionPreference = 'Continue'
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "Fake HTTP listening on http://127.0.0.1:$Port/ (log: $LogPath)"

try {
    while ($true) {
        $ctx = $listener.GetContext()
        try {
            $path = $ctx.Request.Url.AbsolutePath
            Add-Content -LiteralPath $LogPath -Value "$($ctx.Request.HttpMethod) $path" -Encoding UTF8
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('<html><body>ok</body></html>')
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'text/html; charset=utf-8'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        catch { }
        finally {
            try { $ctx.Response.Close() } catch { }
        }
    }
}
finally {
    try { $listener.Stop() } catch { }
}
