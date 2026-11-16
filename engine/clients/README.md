# Clients

One client is one customer of the mailer. A client profile decides everything
a recipient can possibly see:

| what | where in the profile |
|---|---|
| the brand | `message.brandName` |
| the sender name and mailbox | `message.fromName`, `message.fromEmail`, `message.replyTo` |
| the message | `message.templatePath`, `message.subject` |
| the links | `message.landingUrl`, `message.unsubscribeUrl`, `message.listUnsubscribe` |
| the postal address | `message.physicalAddress` |
| the audience | `message.allowedDomains` |
| the SMTP account | `smtp` |
| the creative rotation | `message.variants`, `message.rotateEvery` |

The name of the mailer itself is not part of a profile. It never appears in a
message: it is the logo of the program and the owner of the license.

## Layout

    clients/
      <id>/
        client.json      the profile
        message.html     the message of this client (optional)
      <id>.json          a profile that needs no extra files

The engine looks for `clients/<id>/client.json` first and then for
`clients/<id>.json`.

## Running a client

    .\tools\Send-Campaign.ps1 -List
    .\tools\Send-Campaign.ps1 -ClientId example -RecipientsPath .\data\recipients.txt -DryRun
    .\tools\Send-Campaign.ps1 -ClientId example -RecipientsPath .\data\recipients.txt

Every client keeps its own checkpoint and its own suppression list under
`state/<id>/`, so one client can never contact an address that another
client suppressed, and an interrupted campaign resumes exactly where it
stopped.

## Several SMTP accounts

A profile may hold one account or a list. With a list the engine opens a
session on the first account, moves to the next one when an account stops
accepting mail, and starts every batch on the next account:

    "smtp": {
      "accounts": [
        { "provider": "suddenlink", "username": "one@suddenlink.net",   "passwordEnv": "OPTONLINE_SMTP_PASSWORD", "label": "sb-1" },
        { "provider": "suddenlink", "username": "two@suddenlink.net",   "passwordEnv": "OPTONLINE_SMTP_PASSWORD", "label": "sb-2" },
        { "provider": "outlook",    "username": "three@outlook.com",    "passwordEnv": "OUTLOOK_SMTP_PASSWORD",  "label": "out-1" }
      ]
    }

The provider decides the server, the port, the encryption and the HELO
domain. `provider` is one of `optimum`, `suddenlink`, `outlook`,
`office365`, or `auto` to detect it from the address.

Passwords are never stored in a profile. Each account names an environment
variable, and the launcher asks for it masked.

## The audience list

A CSV keeps every column, so extra columns work as `{{placeholders}}`.
A plain text file holds one address per line, optionally followed by a comma
and a name. Ten thousand lines load in well under a second:

    jane.doe@charter.net,Jane Doe
    john.roe@spectrum.net,John Roe
    sample.user@neo.rr.com

Blank lines and lines that start with `#` are ignored, an address that is not
valid is dropped, and a duplicate is kept only once.

## Wording filter

`message.spamFilter` removes the vocabulary that bulk filters react to, and
nothing else. Every other word of the message is sent exactly as written, the
sender and the domain are never touched, and a link is never rewritten. A
client can add its own terms:

    "spamFilter": {
      "enabled": true,
      "terms": { "instant delivery": "next-day delivery" }
    }

Set `"enabled": false` to switch the filter off for a client.

## Short links

With `message.linkService` the link in the message becomes a short code on
the operator's own host. The engine writes `links.json` next to the project;
publish it together with the redirect page and the short links resolve to the
target of the creative.

    "linkService": { "enabled": true, "baseUrl": "https://example.com" }

The link that goes out is `https://example.com/s/<code>?uid=<token>`: the
code is stable for a creative, the token identifies the recipient.

## The proxy: replacing the exit IP

The mail goes out through a residential proxy and the exit IP is replaced
every `rotationEvery` messages. Three families are supported; the account,
the host, the port and the password always come from the operator.

| family | `proxy.provider` | what the engine builds |
|---|---|---|
| 9Proxy | `9proxy` | `acct-country-us-st-ny-city-nyc-isp-x-sst-10-ssid-<session>` |
| 711Proxy | `711proxy` | `acct-zone-custom-region-US-st-Florida-city-Miami-sessTime-5-session-(<session>)` |
| anything else | `custom` | the pattern you write, with `{country}` `{state}` `{city}` `{isp}` `{session}` `{sessionTime}` |

```json
"proxy": {
  "provider": "711proxy",
  "mode": "gateway",
  "host": "gate.711proxy.com",
  "port": 12345,
  "usernameTemplate": "your-sub-account",
  "passwordEnv": "SEVEN11PROXY_PASSWORD",
  "country": "us",
  "state": "Florida",
  "city": "Miami",
  "sessionTimeMinutes": 5,
  "rotationEvery": 150
}
```

| mode | meaning |
|---|---|
| `gateway` | one fixed host and port; the session token in the username picks the exit IP |
| `ports` | one host and a list of ports, every port is a different exit IP |
| `local` | the 9Proxy desktop application forwards a residential IP to `127.0.0.1:<port>` |
| `none` | no proxy, the mail leaves with the address of the machine |

The password variable follows the family (`NINEPROXY_PASSWORD` for 9Proxy,
`SEVEN11PROXY_PASSWORD` for 711Proxy) unless `passwordEnv` says otherwise.

Check the tunnel before a campaign:

    .\tools\Test-Proxy.ps1 -ClientId acme -Count 3

It prints the exit IP of every attempt and tells you whether the addresses
really changed.
