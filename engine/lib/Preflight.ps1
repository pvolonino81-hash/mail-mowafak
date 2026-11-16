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
  Preflight validation.

  Runs before a batch is released and again before each individual send.
  Findings are graded:

    error  - blocks the send
    warn   - allowed but reported

  Checks cover the things that actually decide whether a batch is worth
  sending: placeholder resolution, required headers, link reachability,
  unsubscribe presence, and DNS authentication records for the sending domain.

  DNS answers are cached for the lifetime of the process. Records do not
  change during a run, and re-querying them for every message would add
  three network round-trips per recipient.
#>

$script:DnsCache = @{}
$script:UrlCache = @{}

function Get-CachedDnsRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('TXT', 'CNAME')][string]$Type
    )
    $key = "$Type|$Name"
    if ($script:DnsCache.ContainsKey($key)) { return $script:DnsCache[$key] }
    $records = @(Get-DnsRecord -Name $Name -Type $Type)
    $script:DnsCache[$key] = $records
    return $records
}

function Get-DnsRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('TXT', 'CNAME')][string]$Type
    )
    try {
        $records = Resolve-DnsName -Name $Name -Type $Type -ErrorAction Stop
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($r in $records) {
            if ($r.Type -eq 'TXT') {
                foreach ($s in $r.StringStrings) { [void]$out.Add($s) }
            }
            elseif ($r.Type -eq 'CNAME' -and $r.NameHost) {
                [void]$out.Add($r.NameHost)
            }
        }
        return $out.ToArray()
    }
    catch {
        return @()
    }
}

function Test-SpfRecord {
    param([Parameter(Mandatory)][string]$Domain)
    $txts = Get-CachedDnsRecord -Name $Domain -Type TXT
    $joined = ($txts -join ' ')
    if ($joined -match 'v=spf1') { return $true }
    return $false
}

function Test-DkimRecord {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [string]$Selector = 'default'
    )
    $name = if ([string]::IsNullOrWhiteSpace($Selector)) { $Domain } else { "$Selector._domainkey.$Domain" }
    $txts = Get-CachedDnsRecord -Name $name -Type TXT
    $joined = ($txts -join ' ')
    if ($joined -match 'v=DKIM1' -or $joined -match 'p=') { return $true }
    return $false
}

function Test-DmarcRecord {
    param([Parameter(Mandatory)][string]$Domain)
    $txts = Get-CachedDnsRecord -Name "_dmarc.$Domain" -Type TXT
    $joined = ($txts -join ' ')
    if ($joined -match 'v=DMARC1') { return $true }
    return $false
}

function Test-UrlReachable {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 15
    )
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5
        $code = [int]$resp.StatusCode
        return [PSCustomObject]@{ Reachable = ($code -ge 200 -and $code -lt 400); Code = $code; Error = $null }
    }
    catch {
        $code = $null
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        }
        # a 4xx still proves the host answers, but it means the link is broken
        if ($code -and $code -ge 400 -and $code -lt 500) {
            return [PSCustomObject]@{ Reachable = $false; Code = $code; Error = "HTTP $code" }
        }
        return [PSCustomObject]@{ Reachable = $false; Code = $code; Error = $_.Exception.Message }
    }
}

function Test-CachedUrlReachable {
    <#
      Reachability check with per-URL memoisation. Every recipient gets a
      unique tracking URL, so only the host and path shape repeat; the cache
      is keyed on URL and only successful checks are reused, which keeps a
      transient failure from being remembered for the rest of the run.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 15
    )
    if ($script:UrlCache.ContainsKey($Url)) { return $script:UrlCache[$Url] }
    $result = Test-UrlReachable -Url $Url -TimeoutSec $TimeoutSec
    if ($result.Reachable) { $script:UrlCache[$Url] = $result }
    return $result
}

function Invoke-Preflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Message,
        [Parameter(Mandatory)][string]$RecipientEmail,
        [string]$TrackingUrl = '',
        [string]$TrackingBaseUrl = '',
        [string]$UnsubscribeUrl = '',
        [string]$UnsubscribeBaseUrl = '',
        [switch]$CheckUrls
    )

    $findings = New-Object System.Collections.Generic.List[object]

    function Add-Finding {
        param([string]$Severity, [string]$Code, [string]$Detail)
        [void]$findings.Add([PSCustomObject]@{ Severity = $Severity; Code = $Code; Detail = $Detail })
    }

    # --- placeholder resolution ---
    $unresolved = Get-UnresolvedTokens -Text $Message.Raw
    if ($unresolved.Count -gt 0) {
        Add-Finding 'error' 'unresolved-token' ("Unresolved placeholders: " + ($unresolved -join ', '))
    }

    # --- required headers ---
    foreach ($h in @('From:', 'To:', 'Subject:', 'Date:', 'Message-ID:', 'MIME-Version:')) {
        if ($Message.Raw -notmatch "(?m)^$([regex]::Escape($h))") {
            Add-Finding 'error' 'missing-header' "Required header '$h' is missing."
        }
    }

    # --- recipient sanity ---
    if ($RecipientEmail -notmatch '^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$') {
        Add-Finding 'error' 'invalid-recipient' "Recipient '$RecipientEmail' is not a valid address."
    }

    # --- body content ---
    if ($Message.Raw -match 'Content-Transfer-Encoding: base64' -and
        $Message.Raw -notmatch 'Content-Type: text/plain') {
        Add-Finding 'error' 'no-text-part' 'Message has no plain-text alternative part.'
    }
    if ($Message.ByteLength -gt 1048576) {
        Add-Finding 'error' 'too-large' "Message is $($Message.ByteLength) bytes, over the 1 MB limit."
    }
    if ($Message.Subject -notmatch '\S') {
        Add-Finding 'error' 'empty-subject' 'Subject line is empty.'
    }
    elseif ($Message.Subject.Length -gt 120) {
        Add-Finding 'warn' 'long-subject' "Subject is $($Message.Subject.Length) characters."
    }

    # --- compliance surface ---
    $msg = Get-ConfigValue -Object $Config -Path 'message'
    $isBulk = [bool](Get-ConfigValue -Object $msg -Path 'requireUnsubscribe' -Default $false)
    if ($isBulk -and $Message.Raw -notmatch '(?m)^List-Unsubscribe:') {
        Add-Finding 'error' 'no-list-unsubscribe' 'List-Unsubscribe header is required but missing.'
    }
    if ($isBulk -and [string]::IsNullOrWhiteSpace((Get-ConfigValue -Object $msg -Path 'physicalAddress' -Default ''))) {
        Add-Finding 'error' 'no-physical-address' 'A physical postal address is required but is not configured.'
    }

    # --- domain authentication ---
    $fromEmail = [string](Get-ConfigValue -Object $msg -Path 'fromEmail' -Default '')
    if ($fromEmail -match '@(.+)$') {
        $domain = $Matches[1]
        $selector = [string](Get-ConfigValue -Object $msg -Path 'dkimSelector' -Default 'default')
        if (-not (Test-SpfRecord -Domain $domain)) {
            Add-Finding 'warn' 'no-spf' "No SPF record found for '$domain'."
        }
        if (-not (Test-DkimRecord -Domain $domain -Selector $selector)) {
            Add-Finding 'warn' 'no-dkim' "No DKIM record found for '$selector._domainkey.$domain'."
        }
        if (-not (Test-DmarcRecord -Domain $domain)) {
            Add-Finding 'warn' 'no-dmarc' "No DMARC record found for '_dmarc.$domain'."
        }
    }
    else {
        Add-Finding 'error' 'bad-from' "fromEmail '$fromEmail' is not a valid address."
    }

    # --- live link checks ---
    # Reachability is checked on the BASE link, not the per-recipient URL.
    # Every recipient carries a unique tracking token, so checking the full
    # URL would mean one network round-trip per message and the cache would
    # never hit. The base link is what actually has to resolve.
    if ($CheckUrls) {
        foreach ($pair in @(
                @{ name = 'tracking link'; base = $TrackingBaseUrl; full = $TrackingUrl },
                @{ name = 'unsubscribe link'; base = $UnsubscribeBaseUrl; full = $UnsubscribeUrl })) {
            $base = $pair.base
            if ([string]::IsNullOrWhiteSpace($base)) {
                if (-not [string]::IsNullOrWhiteSpace($pair.full)) {
                    $base = $pair.full
                }
                elseif ($isBulk -and $pair.name -eq 'unsubscribe link') {
                    Add-Finding 'error' 'no-unsubscribe-url' 'No unsubscribe URL is configured.'
                }
                continue
            }

            # the per-recipient URL must be built from the base
            if (-not [string]::IsNullOrWhiteSpace($pair.full) -and -not $pair.full.StartsWith($base)) {
                Add-Finding 'error' 'link-mismatch' "$($pair.name) does not match its base link '$base'."
                continue
            }

            $r = Test-CachedUrlReachable -Url $base
            if (-not $r.Reachable) {
                Add-Finding 'error' 'unreachable-link' "$($pair.name) is not reachable: $($r.Error)"
            }
        }
    }

    $errors = @($findings | Where-Object { $_.Severity -eq 'error' })
    $warns = @($findings | Where-Object { $_.Severity -eq 'warn' })

    return [PSCustomObject]@{
        Passed      = ($errors.Count -eq 0)
        ErrorCount  = $errors.Count
        WarnCount   = $warns.Count
        Findings    = $findings.ToArray()
        CheckedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
