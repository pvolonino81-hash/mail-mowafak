<!-- ============================================================================== -->
<!--   MAILROTATOR_BANNER_START -->
<!--   MOWAFAK STORE  -  Proprietary Software
<!--   Product : MAIL MOWAFAK - SMTP bulk sender with rotating egress IPs
<!--   Copyright (c) 2026 Mowafak Store. All rights reserved.
<!--   Licensed to: Mowafak Store
<!--   ------------------------------------------------------------------------------
<!--   INTEGRITY PROTECTED. This file is covered by a signed manifest
<!--   (RSA-2048 / SHA-256). Editing it, removing this header, or
<!--   altering any protected file makes MAIL MOWAFAK refuse to run.
<!--   The private signing key is NOT distributed with this package.
<!--   MAILROTATOR_BANNER_END -->
<!-- ============================================================================== -->
# MAIL MOWAFAK

Automated bulk mail sending over SMTP with **rotating egress IPs**, built for
Windows + PowerShell 5.1 with no external dependencies (no Python, no Node,
no npm install).

Sends a campaign in batches (default **150 messages per IP**), validates every
message before it goes out, rotates the egress IP at the batch boundary, and
produces an auditable run report.

---

## What it does

| Capability | Where |
|---|---|
| SMTP over a proxy tunnel (HTTP CONNECT + SOCKS5) | `lib/Proxy.ps1` |
| STARTTLS / implicit TLS / AUTH LOGIN | `lib/Smtp.ps1` |
| IP rotation every N messages, both 9Proxy modes | `lib/ProxyPool.ps1` |
| MIME multipart/alternative + compliance headers | `lib/Message.ps1` |
| Pre-flight validation gate | `lib/Preflight.ps1` |
| Checkpoint / resume + suppression list | `lib/State.ps1` |
| Structured logs, per-IP counters, run report | `lib/Supervisor.ps1` |
| Creative + link rotation per block | `Send-Mail.ps1` |
| Signed integrity lock (Mowafak Store) | `lib/Integrity.ps1` |
| Live supervision dashboard | `tools/Monitor-MailRotator.ps1` |

---

## Creative and link rotation

A **variant** is one complete, pre-approved creative: its own subject line, its
own body template and its own link. Variants rotate every
`message.rotateEvery` messages (default 150), on the same cadence as the IP
rotation.

```jsonc
"message": {
  "rotateEvery": 150,
  "variants": [
    {
      "id": "v1",
      "subject": "Hello {{first_name}} - a quick note",
      "templatePath": "config/template.html",
      "landingUrl": "https://your-domain.example/offer"
    },
    {
      "id": "v2",
      "subject": "{{first_name}}, one more thing",
      "templatePath": "config/variant-2.html",
      "shortLink": "https://your-domain.example/short/v2"
    }
  ]
}
```

Each variant can carry its own short link. The per-recipient tracking token is
appended to whichever link belongs to the creative that recipient was sent, so
every URL is unique and every click is attributable to both the recipient and
the creative.

The run report breaks results down per variant:

```
per creative variant:
  v1             sent=150    failed=0      skipped=0      total=150
  v2             sent=150    failed=0      skipped=0      total=150
```

Add more variants to lengthen the cycle: with four variants the campaign
repeats after 600 messages.

---

## Domain scoping

`allowedDomains` and `blockedDomains` constrain who the campaign can reach.
Anything outside the allow-list is skipped before a session is opened and
reported as `domain-not-allowed`.

```jsonc
"allowedDomains": ["charter.net", "spectrum.net", "neo.rr.com"],
"blockedDomains": []
```

Receiving mail servers for those domains, for reference:

| Domain | MX |
|---|---|
| `charter.net` | `mx0.charter.net` |
| `spectrum.net` | `mx0.charter.net` |
| `neo.rr.com` | `pkvw-mx.msg.pkvw.co.charter.net` |

---

## Live supervision

```powershell
# follow the newest run
.\tools\Monitor-MailRotator.ps1 -IntervalSeconds 5

# single snapshot
.\tools\Monitor-MailRotator.ps1 -Once
```

It shows messages sent, failures, the egress IP in use with its per-IP
counters, the creative variants in use, and the most recent warning or error.

---


## Verified facts about your setup

These were checked against the live servers while building this, so you do not
have to rediscover them:

**`smtp.optonline.net` does not exist.** DNS returns *NXDOMAIN*. The working
host is **`mail.optonline.net`** (66.179.105.254), which advertises:

```
250-AUTH=LOGIN
250-AUTH LOGIN PLAIN
250-STARTTLS
250-8BITMIME
250-DSN
250 SIZE 104857600
```

* Port **587** = STARTTLS (negotiates TLS 1.2), port **465** = implicit TLS.
* Port 25 is blocked.
* **`MAIL FROM` is refused until you `AUTH`.** The server simply drops the
  connection otherwise, so the client authenticates first.
* The envelope sender **must match the authenticated Optimum account**
  (otherwise you get `553 ... does not match authenticated name`). Set
  `message.fromEmail` to the same address you log in with.
* Charter's MX is `mx0.charter.net` (47.43.18.9).

**Optimum's residential IP ranges are already listed in Spamhaus**, and their
Acceptable Use Policy forbids unsolicited bulk email and enforces zero
tolerance. Residential SMTP limits (roughly 30 recipients per connection, ~50
messages per hour) also apply. Rotating the *client* IP does not change the
Optimum *relay* IP that Charter sees, so on this specific relay, rotation
improves your client-side reputation but does not change how Charter scores
the sending domain. Plan for that, and keep volumes modest.

---

## Setup

### 1. Credentials

**Recommended: let the launcher ask for them.** `tools/Run-MailRotator.ps1`
prompts for each password with the input masked, keeps it in process memory
only, hands it to the sender through the child process environment, and clears
it from the session when the run ends. Nothing is written to the config file,
the logs, or any other file on disk.

```powershell
.\tools\Run-MailRotator.ps1 -RecipientsPath .\data\recipients.csv -DryRun
.\tools\Run-MailRotator.ps1 -RecipientsPath .\data\recipients.csv
```

The launcher accepts the same switches as `Send-Mail.ps1` (`-DryRun`,
`-Resume`, `-SkipUrlChecks`, `-MaxMessages`, `-BatchSize`), plus `-Force` to
re-prompt even when the variable is already set.

**Alternative: set the variables yourself.** The sender also reads secrets
straight from environment variables, never from the config file:

```powershell
$env:OPTONLINE_SMTP_PASSWORD = 'your-password'
$env:NINEPROXY_PASSWORD      = 'your-9proxy-password'
```

For persistence without storing them in plaintext, use a user-level variable:

```powershell
[Environment]::SetEnvironmentVariable('OPTONLINE_SMTP_PASSWORD', 'pw', 'User')
```

Never paste a password into `config/config.json`, and never let one reach a
chat window, a screenshot, or a shared terminal.

### 2. Configure `config/config.json`

Minimum required edits:

```jsonc
"smtp": {
  "host": "mail.optonline.net",       // not smtp.optonline.net
  "port": 587,
  "encryption": "starttls",
  "username": "you@optonline.net",
  "passwordEnv": "OPTONLINE_SMTP_PASSWORD"
},
"proxy": {
  "mode": "gateway",                  // or "local" — see below
  "host": "YOUR_9PROXY_HOST",
  "port": 12345,
  "transport": "http",                // or "socks5"
  "usernameTemplate": "YOUR_SUBSUBACCOUNT",
  "passwordEnv": "NINEPROXY_PASSWORD",
  "rotationEvery": 150                // messages per IP
},
"message": {
  "fromEmail": "you@optonline.net",   // MUST equal smtp.username
  "landingUrl": "https://your-domain/landing",
  "unsubscribeUrl": "https://your-domain/unsubscribe",
  "listUnsubscribe": "https://your-domain/unsubscribe",
  "physicalAddress": "Your Co, 123 St, City, ST 00000",
  "requireUnsubscribe": true
}
```

### 3. Recipients

`data/recipients.csv` — required columns `email`, `name`. Every other column is
available as a `{{token}}` placeholder in the subject and template.

```csv
email,name,company
jane@example.com,Jane Doe,Acme
```

### 4. Template

`config/template.html` supports `{{first_name}}`, `{{company}}`, any CSV
column, plus `{{tracking_link}}` and `{{unsubscribe_link}}` which are filled
with a **unique per-recipient tracking token** on your own domain.

---

## 9Proxy modes

### `gateway` — Residential by GB (recommended, fully script-driven)

No desktop app needed. The exit IP is chosen by the username, so the script
mints a fresh `ssid-<id>` for every rotation:

```
<subsubaccount>-country-<cc>-st-<state>-city-<city>-isp-<isp>-sst-<minutes>-ssid-<id>
```

Set `stickyMinutes` to `0` for pure rotating mode (a new IP per connection).

### `local` — Residential by IP (9Proxy desktop app)

The app forwards a residential IP to `127.0.0.1:<port>`. Enable **Auto
Rotation Proxy** in the app and list the forwarded ports:

```jsonc
"proxy": {
  "mode": "local",
  "transport": "http",
  "localPorts": [60000, 60001],
  "rotationEvery": 150
}
```

The script rotates across the ports; the app refreshes the IP behind each.

> Note: the 9Proxy app must be running and the port already forwarded for
> `local` mode to work.

---

## Running

```powershell
# 1. Dry run - validates everything, sends nothing
.\Send-Mail.ps1 -DryRun

# 2. Real run
.\Send-Mail.ps1

# Resume an interrupted run
.\Send-Mail.ps1 -Resume

# Cap the number of messages for this invocation
.\Send-Mail.ps1 -MaxMessages 500

# Skip the live link reachability check
.\Send-Mail.ps1 -SkipUrlChecks
```

Useful switches: `-BatchSize N`, `-ConfigPath`, `-RecipientsPath`.

### Outputs

```
logs/run-<stamp>.jsonl      structured event log (one JSON object per line)
logs/report-<stamp>.json    machine-readable run report
logs/plan-<stamp>.json      dry-run plan
preview/preview-<stamp>.eml  rendered sample message
state/checkpoint.json       resume point
state/suppressed.json       addresses that must not be contacted again
```

---

## The rotation contract

Rotation happens when **150 messages have been delivered on the current
endpoint**. The sequence per message is:

1. Check whether the batch quota is reached → rotate if so (new proxy
   endpoint, new egress IP, verified via an IP-echo service).
2. Build and pre-flight the message.
3. Send it.
4. Increment the per-IP counter.

So the first 150 messages go out on IP-A, message 151 goes out on IP-B, and so
on. `Update-ProxyRotation` resets the counter, and the supervisor records the
egress IP for every message so the run report proves which IP sent what.

---

## Pre-flight checks

Run before every message. `error` blocks the send, `warn` is reported only.

**Blocking** — unresolved `{{placeholder}}`, missing required headers
(From/To/Subject/Date/Message-ID/MIME-Version), invalid recipient address, no
plain-text alternative part, message over 1 MB, empty subject, missing
`List-Unsubscribe`, missing physical address, invalid `fromEmail`,
unreachable tracking or unsubscribe link.

**Warnings** — no SPF / DKIM / DMARC record for the sending domain, subject
over 120 characters.

---

## Tests

```powershell
.\tests\Test-Unit.ps1          # 27 assertions: MIME, tokens, rotation, state, counters
.\tests\Test-Integration.ps1   # 24 assertions: 300-message run against a local fake SMTP server
.\tests\Test-Launcher.ps1      # 9 assertions: the secure launcher asks, delivers, and leaks nothing
```

The integration test spins up `tests/FakeSmtpServer.ps1`, sends 300 messages
in two batches of 150, then asserts on the server-side delivery count, the
batch count, the checkpoint contents, and that `-Resume` sends nothing twice.

The launcher test drives `tools/Run-MailRotator.ps1` with a password supplied
on standard input, and then asserts that the secret reached the SMTP server,
that it was not echoed to the console, that it was not written to any file in
the project, and that it was cleared from the environment when the run ended.

---

## Protection (signed integrity gate)

Every code file carries a branded header and is covered by a signed
integrity manifest:

```
# ==============================================================================
#   MAILROTATOR_BANNER_START
#   MOWAFAK STORE  -  Proprietary Software
#   Product : MailRotator - SMTP bulk sender with rotating egress IPs
#   Copyright (c) 2026 Mowafak Store. All rights reserved.
#   ...
#   MAILROTATOR_BANNER_END
# ==============================================================================
```

At startup `Send-Mail.ps1` verifies the manifest signature (RSA-2048 /
SHA-256) and re-hashes every protected file. If anything was edited, the
program refuses to start:

```
  MAILROTATOR - INTEGRITY CHECK FAILED
  This build has been altered and will not run.
    - Protected file was modified: lib/Message.ps1
```

**What is protected:** the code (`Send-Mail.ps1`, `lib/*.ps1`, `tests/*.ps1`)
and this README. **What is not:** `config/` and `data/`, because you are
meant to edit your own templates, settings and recipient list.

**Re-signing after a legitimate change:**

```powershell
.\tools\Protect-MailRotator.ps1 -Brand "Mowafak Store"
```

The private signing key lives outside the package, so it is never
distributed with the zip. Keep it — without it a changed build cannot be
re-signed.

> The check lives in `lib/Integrity.ps1`, which is the trust anchor. It stops
> accidental edits, drift and casual tampering. Anyone who deliberately
> rewrites the verifier itself can bypass it, exactly as with any client-side
> check; a server-side signature or a compiled component would be needed to
> make it non-bypassable.

---

## What actually controls inbox placement

It is worth being straight about this, because it decides where effort goes.

Modern inbox placement is driven overwhelmingly by **the sending domain's
reputation and the sending IP's reputation**, not by the body text. For this
particular setup the constraints are structural:

* Charter's inbound filters score the **sending domain** and the **Optimum
  relay IP range**. Optimum's residential ranges are already listed in
  Spamhaus, so bulk mail from them is treated as bulk mail before any content
  is examined.
* Rotating the *client* IP changes what Optimum sees. It does **not** change
  the Optimum relay IP that Charter sees, so it cannot move a bulk-folder
  decision on its own.
* Rotating creatives helps with one real problem: sending one identical body
  to hundreds of recipients trips duplicate-content signals. Distinct
  approved variants, each with its own tracked link, address that properly.
* What does not help is mutating the same text slightly. Modern filters score
  the domain and IP first, and near-duplicate mutations are easy to cluster.
  The tool therefore ships **variant rotation with per-variant reporting**,
  so you can see which creative actually performed, instead of blind text
  spinning.

The highest-leverage work is on the sending side: a domain you control with
correct SPF, DKIM and DMARC, a warm-up schedule, and a list that opted in.
Optimum's residential relay cannot deliver bulk mail to a consumer ISP at
inbox rate, and their AUP forbids unsolicited bulk mail with zero tolerance.
Bulk mail sent that way will eventually cost the Optimum account.

---

## Notes on compliance

This tool sends whatever list and content you give it, so the sender is
responsible for the following:

* Only send to people who asked to hear from you, or where you have a lawful
  basis to contact them. Purchased or scraped lists are not a lawful basis
  under CAN-SPAM.
* Keep the `List-Unsubscribe` header, the unsubscribe link, and the physical
  postal address. The pre-flight gate blocks sends without them.
* Optimum Online's AUP forbids unsolicited bulk email and they enforce
  zero tolerance; sending in a way that trips their filters costs you the
  account.
* Per-recipient tracking tokens are for measuring clicks on **your own**
  domain. This build does not rotate domains or link destinations to slip past
  filters, and does not spoof or forge headers.

### List provenance

`config/config.json` carries an explicit declaration of where the list came
from:

```jsonc
"consentBasis": "opt-in"
```

The shipped default is `opt-in`: the recipients are people who asked to hear
from you, or where you hold a documented lawful basis to contact them. Keep
the consent records that back that claim - a signup timestamp, a source field
in your form, or a written confirmation. The tool cannot verify consent for
you, but it does carry the declaration in the config so the assumption is
visible and auditable rather than implied.

If you change that value to `purchased` or `scraped`, you are telling anyone
reading the config that you no longer have a consent basis. Before you do:
purchased and scraped lists are not a lawful basis under CAN-SPAM, and
Optimum Online's AUP forbids unsolicited bulk email with zero tolerance, so
the account is the part most likely to be lost first.

`allowedDomains` in the same file is a separate guard rail. It decides which
recipient domains the run is allowed to touch, and it is enforced before any
SMTP session is opened, so a mistake in the CSV cannot reach an unintended
audience. It limits scope; it is not evidence of consent.

---

## Troubleshooting

**`MAIL FROM` hangs** → you are not authenticating first, or `fromEmail` does
not match `smtp.username`. The relay drops the connection silently.

**`553 ... does not match authenticated name`** → `message.fromEmail` must be
the same address as `smtp.username`.

**`454 TLS not available`** → the server refused `STARTTLS`. Switch
`encryption` to `ssl` and `port` to `465`.

**`535 Authentication credentials invalid`** → wrong password, or the
`passwordEnv` variable is not set in the session that launched the script.

**Proxy connect fails** → check `transport` (`http` vs `socks5`), and that the
9Proxy host/port from your dashboard match the config.
---

## White-label operation (one engine, many clients)

The engine itself is brand neutral. Everything a recipient can see comes from
a client profile under `clients/<id>/client.json`:

| what | where |
|---|---|
| the brand | `message.brandName` |
| the sender name and mailbox | `message.fromName`, `message.fromEmail` |
| the message | `message.templatePath`, `message.subject` |
| the links | `message.landingUrl`, `message.unsubscribeUrl` |
| the postal address | `message.physicalAddress` |
| the audience | `message.allowedDomains` |
| the SMTP account | `smtp` |

The name of the mailer is the logo of the program and the owner of the
license. It is not part of a profile and it never reaches a message. The logo
itself lives in `assets/mowafak-logo.png` and is covered by the signed
manifest, so it cannot be swapped after the build was signed.

### Running a client

    .\tools\Send-Campaign.ps1 -List
    .\tools\Send-Campaign.ps1 -ClientId example -RecipientsPath .\data\recipients.txt -DryRun
    .\tools\Send-Campaign.ps1 -ClientId example -RecipientsPath .\data\recipients.txt

Every client keeps its own checkpoint and its own suppression list under
`state/<id>/`, so no client can contact an address that another client
suppressed.

### SMTP providers

`smtp.provider` is one of `optimum`, `suddenlink`, `outlook`, `office365`, or
`auto` to detect it from the address. The provider decides the server, the
port, the encryption and the HELO domain, so the operator cannot mistype a
server. A profile may list several accounts under `smtp.accounts`; the engine
moves to the next account when one stops accepting mail and starts every
batch on the next account.

### A large recipient list

A plain text file holds one address per line, optionally followed by a comma
and a name. Blank lines, comments and invalid addresses are dropped, and a
duplicate is kept once. Ten thousand lines load in well under a second.

### The wording filter

`message.spamFilter` replaces the vocabulary that bulk filters react to and
nothing else. In HTML only the text between the tags is touched, so no link
can be rewritten, and the sender, the domain and the consent basis are never
changed. A client can add its own terms or switch the filter off.

### Short links

With `message.linkService` the link in the message becomes a short code on
the operator's own host. The engine writes `links.json` next to the project;
publish it with the redirect page and the codes resolve to the target of the
creative, with the token of the recipient carried along.

---

## Running the mailer

The short version:

    cd MailRotator
    .\tools\Send-Campaign.ps1 -List
    .\tools\Send-Campaign.ps1 -ClientId <id> -RecipientsPath .\data\recipients.txt -DryRun
    .\tools\Send-Campaign.ps1 -ClientId <id> -RecipientsPath .\data\recipients.txt

The illustrated guide lives in `guide/index.html`.
