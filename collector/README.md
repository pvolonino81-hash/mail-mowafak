# Drill collector

Source for the training collector that ships as a Cloudflare Worker / Pages function.

- Routes: /page /o /c /download/label.html /download/fleetdeck.exe /verified /u /count /stats /checksums.txt
- Storage: Cloudflare D1 database named 'drill', table 'events'
- Deploy target: Cloudflare Pages project 'mowafak-drill' (host mowafak-drill.pages.dev)
- Required bindings: DB (D1) and STATS_KEY (guards the /stats route)
