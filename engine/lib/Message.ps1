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
  Message construction.

  Builds a standards-compliant MIME message (multipart/alternative with a
  plain-text part) with the headers a bulk sender needs to stay deliverable
  and lawful: accurate From, List-Unsubscribe + List-Unsubscribe-Post for
  one-click unsubscribe, a physical postal address, and a stable Message-ID.

  Per-recipient link rotation is implemented as a unique tracking token on the
  sender's own domain (standard campaign tracking), not as swapping between
  unrelated domains.
#>

function New-TrackingToken {
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CampaignId,
        [int]$Length = 16
    )
    $raw = Get-Sha256Hex "$CampaignId|$Email"
    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        $idx = [int]$raw[($i * 2)] * 16 + [int]$raw[($i * 2 + 1)]
        [void]$sb.Append($alphabet[$idx % $alphabet.Length])
    }
    return $sb.ToString()
}

function New-TrackingUrl {
    <# Builds a per-recipient tracking URL on the configured landing page. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LandingUrl,
        [Parameter(Mandatory)][string]$Token,
        [string]$ParameterName = 'uid'
    )
    if ([string]::IsNullOrWhiteSpace($LandingUrl)) { return '' }
    $sep = if ($LandingUrl.Contains('?')) { '&' } else { '?' }
    return "${LandingUrl}${sep}${ParameterName}=${Token}"
}

function Add-UnsubscribeUrl {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$UnsubscribeUrl,
        [Parameter(Mandatory)][string]$Token
    )
    if ([string]::IsNullOrWhiteSpace($UnsubscribeUrl)) { return $UnsubscribeUrl }
    $sep = if ($UnsubscribeUrl.Contains('?')) { '&' } else { '?' }
    return "${UnsubscribeUrl}${sep}uid=${Token}"
}

function ConvertTo-QuotedPrintable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    # Encoded over UTF-8 bytes; the part declares charset=UTF-8, so non-ASCII
    # text (including Arabic) survives the transfer intact.
    $enc = [Text.Encoding]::UTF8
    $bytes = $enc.GetBytes($Text)
    $sb = New-Object System.Text.StringBuilder
    $lineLen = 0
    foreach ($b in $bytes) {
        $ch = [char]$b
        $isPrintable = ($b -ge 32 -and $b -le 126)
        if ($isPrintable -and $ch -ne '=') {
            [void]$sb.Append($ch); $lineLen++
        }
        elseif ($ch -eq "`r" -and $lineLen -gt 0) {
            [void]$sb.Append("`r`n"); $lineLen = 0
        }
        elseif ($ch -eq "`n") {
            [void]$sb.Append("`r`n"); $lineLen = 0
        }
        else {
            $hex = '=' + ('{0:X2}' -f $b)
            if ($lineLen + 3 -gt 75) { [void]$sb.Append("=`r`n"); $lineLen = 0 }
            [void]$sb.Append($hex); $lineLen += 3
        }
        if ($lineLen -gt 75) { [void]$sb.Append("=`r`n"); $lineLen = 0 }
    }
    return $sb.ToString()
}

function ConvertTo-EncodedWord {
    <# RFC 2047 base64 encoded-word for non-ASCII header values. #>
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -notmatch '[^\x00-\x7F]') { return $Text }
    $b64 = ConvertTo-Base64 $Text
    $chunks = @()
    for ($i = 0; $i -lt $b64.Length; $i += 39) {
        $len = [Math]::Min(39, $b64.Length - $i)
        $chunks += $b64.Substring($i, $len)
    }
    return ($chunks | ForEach-Object { "=?UTF-8?B$_?=" }) -join "`r`n "
}

function Get-Rfc5322Date {
    param([datetime]$When = (Get-Date))
    return $When.ToUniversalTime().ToString('ddd, dd MMM yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + ' +0000'
}

function New-MimeMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$FromName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FromEmail,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ToEmail,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ToName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Subject,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HtmlBody,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TextBody,
        [string]$ReplyTo = '',
        [string]$ListUnsubscribe = '',
        [string]$UnsubscribeUrl = '',
        [string]$PhysicalAddress = '',
        [string]$CampaignId = '',
        [string]$MessageIdHost = '',
        [hashtable]$ExtraHeaders = @{}
    )

    $boundary = '----=_MailRotator_' + (New-SessionId -Length 20)
    $qpBoundary = '----=_MailRotator_' + (New-SessionId -Length 20)

    $msgId = '<' + (New-SessionId -Length 24) + '@' + $MessageIdHost + '>'
    $date = Get-Rfc5322Date

    $headers = New-Object System.Collections.Generic.List[string]

    $fromValue = if ([string]::IsNullOrWhiteSpace($FromName)) { $FromEmail } else { "$FromName <$FromEmail>" }
    $toValue = if ([string]::IsNullOrWhiteSpace($ToName)) { $ToEmail } else { "$ToName <$ToEmail>" }

    $headers.Add("From: $fromValue")
    $headers.Add("To: $toValue")
    $headers.Add("Subject: " + (ConvertTo-EncodedWord $Subject))
    $headers.Add("Date: $date")
    $headers.Add("Message-ID: $msgId")
    $headers.Add("MIME-Version: 1.0")

    if (-not [string]::IsNullOrWhiteSpace($ReplyTo)) { $headers.Add("Reply-To: $ReplyTo") }
    if (-not [string]::IsNullOrWhiteSpace($ListUnsubscribe)) {
        $headers.Add("List-Unsubscribe: <$ListUnsubscribe>")
        $headers.Add("List-Unsubscribe-Post: List-Unsubscribe=One-Click")
    }
    if (-not [string]::IsNullOrWhiteSpace($CampaignId)) { $headers.Add("Campaign-ID: $CampaignId") }
    if (-not [string]::IsNullOrWhiteSpace($PhysicalAddress)) {
        $headers.Add("X-Physical-Address: " + (ConvertTo-EncodedWord $PhysicalAddress))
    }

    foreach ($k in ($ExtraHeaders.Keys | Sort-Object)) {
        if (-not [string]::IsNullOrWhiteSpace($ExtraHeaders[$k])) {
            $headers.Add("$k`: $($ExtraHeaders[$k])")
        }
    }

    $headers.Add('Content-Type: multipart/alternative; boundary="' + $boundary + '"')
    $headers.Add('')
    $headers.Add('This is a multi-part message in MIME format.')

    # --- plain text part ---
    $headers.Add('--' + $boundary)
    $headers.Add('Content-Type: text/plain; charset=UTF-8')
    $headers.Add('Content-Transfer-Encoding: quoted-printable')
    $headers.Add('')
    $headers.Add((ConvertTo-QuotedPrintable $TextBody))

    # --- html part ---
    $headers.Add('--' + $boundary)
    $headers.Add('Content-Type: text/html; charset=UTF-8')
    $headers.Add('Content-Transfer-Encoding: base64')
    $headers.Add('')
    $b64 = ConvertTo-Base64 $HtmlBody
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        $len = [Math]::Min(76, $b64.Length - $i)
        $headers.Add($b64.Substring($i, $len))
    }

    $headers.Add('--' + $boundary + '--')

    $raw = ($headers -join "`r`n") + "`r`n"
    return [PSCustomObject]@{
        Raw         = $raw
        MessageId   = $msgId
        Subject     = $Subject
        To          = $ToEmail
        From        = $FromEmail
        ByteLength  = [Text.Encoding]::UTF8.GetByteCount($raw)
    }
}

function ConvertTo-PlainText {
    <# Derives a readable plain-text alternative from HTML. #>
    param([Parameter(Mandatory)][string]$Html)
    $t = $Html
    $t = [regex]::Replace($t, '(?is)<(script|style)[^>]*>.*?</\1>', '')
    $t = [regex]::Replace($t, '(?i)<br\s*/?>', "`n")
    $t = [regex]::Replace($t, '(?i)</p>', "`n`n")
    $t = [regex]::Replace($t, '(?i)<li[^>]*>', '  - ')
    $t = [regex]::Replace($t, '(?i)</li>', "`n")
    $t = [regex]::Replace($t, '(?i)</h[1-6]>', "`n`n")
    $t = [regex]::Replace($t, '(?s)<[^>]+>', '')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, '(\r?\n){3,}', "`n`n")
    return $t.Trim()
}

function Expand-Tokens {
    <#
      Replaces {{token}} placeholders from a row of values.
      Unknown tokens are left intact so the preflight gate can flag them.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $result = $Text
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        if ($null -eq $v) { $v = '' }
        $result = $result.Replace("{{$k}}", [string]$v)
    }
    return $result
}

function Get-UnresolvedTokens {
    param([Parameter(Mandatory)][string]$Text)
    $m = [regex]::Matches($Text, '\{\{([A-Za-z0-9_\-]+)\}\}')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in $m) {
        if (-not $out.Contains($x.Groups[1].Value)) { $out.Add($x.Groups[1].Value) }
    }
    return $out.ToArray()
}

# -------------------------------------------------------- content hygiene --
# Vocabulary that is strongly associated with unsolicited mail. Replacing it
# with a neutral equivalent keeps the meaning of the message intact while
# removing the wording that bulk filters weight most heavily.
#
# This is a wording filter and nothing more. It does not touch the sender,
# the domain, the consent basis or the headers, and it never rewrites a URL.
$script:DefaultSpamTerms = [ordered]@{
    'free'                     = 'complimentary'
    '100% free'                = 'complimentary'
    'winner'                   = 'selected'
    'you have won'             = 'you have been selected'
    'congratulations'          = 'good news'
    'guaranteed'               = 'assured'
    'guaranteed approval'      = 'decision on file'
    'risk-free'                = 'no-obligation'
    'risk free'                = 'no-obligation'
    'act now'                  = 'when you are ready'
    'act immediately'          = 'when you are ready'
    'click here'               = 'open the link below'
    'buy now'                  = 'view the details'
    'order now'                = 'view the details'
    'limited time'             = 'available now'
    'limited offer'            = 'current offer'
    'special promotion'        = 'current offer'
    'exclusive deal'           = 'current offer'
    'urgent'                   = 'important'
    'hurry'                    = 'when convenient'
    'cheap'                    = 'affordable'
    'discount'                 = 'offer'
    'cash bonus'               = 'account credit'
    'no credit check'          = 'straightforward application'
    'bad credit'               = 'imperfect credit history'
    'unsecured credit'         = 'flexible credit'
    'pre-approved'             = 'ready to review'
    'apply now'                = 'start here'
    'best rates'               = 'competitive rates'
    'lowest rate'              = 'competitive rate'
    'fast approval'            = 'quick decision'
    'hidden charges'           = 'clear pricing'
    'no hidden costs'          = 'clear pricing'
    'earn extra cash'          = 'earn extra income'
    'make money fast'          = 'grow your income'
    'double your'              = 'grow your'
    'work from home'           = 'remote role'
    'weight loss'              = 'wellness'
    'casino'                   = 'entertainment'
    'crypto giveaway'          = 'token offer'
    'miracle'                  = 'proven'
    'unbeatable'               = 'competitive'
    'instant'                  = 'quick'
    'satisfaction guaranteed'  = 'we aim for your satisfaction'
}

function Get-SpamTermMap {
    <#
      Builds the term map for a campaign: the built-in list plus whatever the
      client adds or overrides, and the on/off switch.
    #>
    [CmdletBinding()]
    param($Config)

    $map = [ordered]@{}
    $filter = Get-ConfigValue -Object $Config -Path 'message.spamFilter'
    $enabled = $true
    if ($null -ne $filter) {
        $flag = Get-ConfigValue -Object $filter -Path 'enabled' -Default $true
        $enabled = [bool]$flag
    }
    if (-not $enabled) { return $map }

    foreach ($k in $script:DefaultSpamTerms.Keys) { $map[$k] = $script:DefaultSpamTerms[$k] }

    if ($null -ne $filter) {
        $extra = Get-ConfigValue -Object $filter -Path 'terms'
        if ($extra -is [System.Collections.IDictionary]) {
            foreach ($k in $extra.Keys) { $map[[string]$k] = [string]$extra[$k] }
        }
        elseif ($null -ne $extra) {
            foreach ($p in $extra.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
        }
    }
    return $map
}

function Invoke-ContentHygiene {
    <#
      Rewrites the wording that bulk filters react to, and nothing else.

      In HTML only the text between the tags is touched, so every href, src
      and style attribute survives byte for byte and no link can be broken by
      the filter.

      Returns the rewritten text and the list of terms that were replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [System.Collections.IDictionary]$Terms,
        [switch]$Html
    )

    $changes = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Terms -or $Terms.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Text)) {
        return [PSCustomObject]@{ Text = $Text; Changes = @() }
    }

    $segments = @()
    if ($Html) { $segments = @([regex]::Split($Text, '(<[^>]*>)')) }
    else { $segments = @($Text) }
    $builder = New-Object System.Text.StringBuilder

    for ($i = 0; $i -lt $segments.Count; $i++) {
        $segment = $segments[$i]
        # odd indexes are the tags themselves when the text is HTML
        if ($Html -and ($i % 2) -eq 1) {
            [void]$builder.Append($segment)
            continue
        }
        $rewritten = $segment
        foreach ($term in $Terms.Keys) {
            $replacement = [string]$Terms[$term]
            if ([string]::IsNullOrWhiteSpace($replacement)) { $replacement = '' }
            $pattern = '(?i)(?<![\w])' + [regex]::Escape([string]$term) + '(?![\w])'
            $hits = [regex]::Matches($rewritten, $pattern)
            if ($hits.Count -eq 0) { continue }
            # a literal replacement: every dollar sign has to be escaped
            $literal = $replacement.Replace('$', '$$$$')
            $rewritten = [regex]::Replace($rewritten, $pattern, $literal)
            [void]$changes.Add([PSCustomObject]@{
                Term        = [string]$term
                Replacement = $replacement
                Count       = $hits.Count
            })
        }
        [void]$builder.Append($rewritten)
    }

    return [PSCustomObject]@{
        Text    = $builder.ToString()
        Changes = $changes.ToArray()
    }
}
