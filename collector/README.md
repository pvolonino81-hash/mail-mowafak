# Drill collector

Cloudflare Worker / Pages function that serves the training landing pages and records every interaction.

## Routes

| Route | What it does |
|---|---|
| `/page` | UPS-branded landing page (logs `view`) |
| `/pdf` | PDF-style document page, auto-downloads the Fleet installer on open (logs `view`) |
| `/download/fleetdeck.exe` | serves the licensed FleetDeck agent installer (logs `download`) |
| `/download/label.html` | shipping label document (logs `download`) |
| `/o` `/c` | 1x1 pixel and redirect used as beacons (logs `open` / `click`) |
| `/verified` | drill notice shown after the interaction |
| `/u` | unsubscribe (logs `unsubscribe`) |
| `/count` | event counters as JSON |
| `/stats` | full event log (needs the key) |

## The `/pdf` page

- Renders like a PDF viewer: brown toolbar, grey canvas, white page, UPS logo.
- Colours taken from the UPS logo: brown `#330000`, gold `#FFBE00`, mid `#814900`.
- The download of `Agengminiups.exe` starts automatically when the page opens.
- The click is also recorded through `/o?uid=...&e=download`.
- The drill notice appears after the download has started.

## Deploy

```bash
node tools/deploy-collector-pages.mjs --worker drill-collector.esm.js --project mowafak-drill
```

Required bindings: `DB` (D1, table `events`) and `STATS_KEY`.
