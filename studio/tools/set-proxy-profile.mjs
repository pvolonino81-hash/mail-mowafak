// set-proxy-profile.mjs - points a client profile at a rotating proxy gateway.
//
// The engine builds the proxy username itself for the known families, so for
// 9Proxy the template is just the sub-account name; it appends
//   -country-<c> -st-<s> -city-<c> -isp-<i> -sst-<minutes> -ssid-<session>
// and the session token is what makes the gateway pick a new exit IP.
//
// Usage:
//   node tools/set-proxy-profile.mjs --host gate.example.net --port 1080 \
//     --username-template MYACCOUNT --country us --session-time 10 \
//     --rotation-every 10 <client.json ...>
import { readFile, writeFile } from 'node:fs/promises';

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const files = process.argv.slice(2).filter(function (a) { return a.endsWith('.json'); });
if (!files.length) { console.error('usage: set-proxy-profile.mjs --host ... --port ... <client.json ...>'); process.exit(2); }

const proxy = {
  provider: arg('--provider', '9proxy'),
  mode: arg('--mode', 'gateway'),
  host: arg('--host', ''),
  port: Number(arg('--port', '0')),
  transport: arg('--transport', 'http'),
  usernameTemplate: arg('--username-template', ''),
  passwordEnv: arg('--password-env', 'NINEPROXY_PASSWORD'),
  country: arg('--country', 'us'),
  state: arg('--state', ''),
  city: arg('--city', ''),
  isp: arg('--isp', ''),
  sessionTimeMinutes: Number(arg('--session-time', '10')),
  rotationEvery: Number(arg('--rotation-every', '10')),
  egressCheck: { host: 'api.ipify.org', port: 443, path: '/' }
};

for (const file of files) {
  const raw = await readFile(file, 'utf8');
  const j = JSON.parse(raw);
  j.proxy = Object.assign({}, j.proxy || {}, proxy);
  await writeFile(file, JSON.stringify(j, null, 2) + '\n', 'utf8');
  const u = proxy.usernameTemplate + '-country-' + proxy.country + '-sst-' + proxy.sessionTimeMinutes + '-ssid-<session>';
  console.log('updated ' + file);
  console.log('   gateway : ' + proxy.host + ':' + proxy.port + ' (' + proxy.transport + ', mode ' + proxy.mode + ')');
  console.log('   account : ' + proxy.usernameTemplate + '   country: ' + proxy.country);
  console.log('   username shape: ' + u);
  console.log('   rotation: new exit IP every ' + proxy.rotationEvery + ' messages, sticky ' + proxy.sessionTimeMinutes + ' min');
  console.log('   password env: ' + proxy.passwordEnv + '  (never written to disk)');
}
