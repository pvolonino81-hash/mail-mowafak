// filter-leads.mjs - cleans a lead list before it reaches the sender.
//
// Usage:
//   node tools/filter-leads.mjs --input list.csv --out data/recipients.csv
//   node tools/filter-leads.mjs --input list.txt --out data/recipients.csv --domains spectrum.net,charter.net
//
// What it does, in order:
//   1. parses CSV / TSV / plain text (one address per line, optional ,name)
//   2. rejects malformed addresses
//   3. removes duplicates (case insensitive)
//   4. drops addresses already on the suppression list
//   5. drops addresses outside the allowed domains (scope guard)
//   6. rejects role accounts (info@, support@, admin@ ...) unless --allow-role
//   7. checks that the domain can receive mail (MX, with an A-record fallback)
//
// The check is a DNS lookup only. No connection is made to the recipient
// server, so the list can be validated without touching anyone's mail server.

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { resolveMx, resolve4, resolve6 } from 'node:dns/promises';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const ROLE_LOCALS = new Set([
  'info', 'support', 'help', 'sales', 'contact', 'admin', 'administrator', 'office',
  'billing', 'accounts', 'accounting', 'noreply', 'no-reply', 'donotreply', 'postmaster',
  'webmaster', 'hostmaster', 'abuse', 'security', 'mail', 'root', 'abuse', 'team', 'service'
]);

function parseArgs(argv) {
  const args = { allowRole: false, domains: [] };
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    const value = argv[i + 1];
    if (key === '--input') { args.input = value; i += 1; }
    else if (key === '--out') { args.out = value; i += 1; }
    else if (key === '--rejected') { args.rejected = value; i += 1; }
    else if (key === '--suppressed') { args.suppressed = value; i += 1; }
    else if (key === '--domains') { args.domains = String(value || '').split(',').map(function (d) { return d.trim().toLowerCase(); }).filter(Boolean); i += 1; }
    else if (key === '--allow-role') { args.allowRole = true; }
    else if (key === '--no-mx-check') { args.noMxCheck = true; }
  }
  return args;
}

function splitRow(line, delimiter) {
  const cells = [];
  let current = '';
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '"') { quoted = !quoted; continue; }
    if (ch === delimiter && !quoted) { cells.push(current.trim()); current = ''; continue; }
    current += ch;
  }
  cells.push(current.trim());
  return cells;
}

export function parseList(text, format) {
  const lines = String(text || '').split(/\r?\n/).filter(function (l) { return l.trim() && !l.trim().startsWith('#'); });
  const rows = [];
  if (lines.length === 0) return rows;

  let delimiter = ',';
  let header = null;
  let body = lines;

  if (format === 'auto' || format === undefined) {
    if (lines[0].includes(',') || lines[0].includes(';') || lines[0].includes('\t')) {
      delimiter = lines[0].includes(';') && !lines[0].includes(',') ? ';' : (lines[0].includes('\t') ? '\t' : ',');
      format = 'csv';
    } else {
      format = 'txt';
    }
  }
  if (format === 'tsv') delimiter = '\t';

  if (format === 'csv') {
    const first = splitRow(lines[0], delimiter).map(function (c) { return c.toLowerCase(); });
    if (first.indexOf('email') >= 0 || first.indexOf('e-mail') >= 0) {
      header = first;
      body = lines.slice(1);
    }
  }

  for (const line of body) {
    if (format === 'txt') {
      const comma = line.indexOf(',');
      const email = (comma >= 0 ? line.slice(0, comma) : line).trim();
      const name = comma >= 0 ? line.slice(comma + 1).trim() : '';
      rows.push({ email: email, name: name, extra: {} });
      continue;
    }
    const cells = splitRow(line, delimiter);
    let email = '';
    let name = '';
    const extra = {};
    if (header) {
      for (let i = 0; i < cells.length; i += 1) {
        const key = header[i] || ('col' + i);
        if (key === 'email' || key === 'e-mail') email = cells[i];
        else if (key === 'name' || key === 'full_name' || key === 'customer_name') name = cells[i];
        else extra[key] = cells[i];
      }
    } else {
      email = cells[0] || '';
      name = cells[1] || '';
      for (let i = 2; i < cells.length; i += 1) extra['col' + i] = cells[i];
    }
    rows.push({ email: email, name: name, extra: extra });
  }
  return rows;
}

async function domainAcceptsMail(domain) {
  try {
    const mx = await resolveMx(domain);
    if (mx && mx.length) return { ok: true, via: 'mx', host: mx[0].exchange };
  } catch (error) { void error; }
  try {
    const a = await resolve4(domain);
    if (a && a.length) return { ok: true, via: 'a', host: a[0] };
  } catch (error) { void error; }
  try {
    const aaaa = await resolve6(domain);
    if (aaaa && aaaa.length) return { ok: true, via: 'aaaa', host: aaaa[0] };
  } catch (error) { void error; }
  return { ok: false, via: 'none', host: '' };
}

export async function filterRows(rows, options) {
  const opts = options || {};
  const allowed = (opts.domains || []).map(function (d) { return d.toLowerCase(); });
  const suppressed = new Set((opts.suppressed || []).map(function (e) { return String(e).toLowerCase(); }));
  const seen = new Set();
  const kept = [];
  const rejected = [];
  const domainCache = new Map();

  for (const row of rows) {
    const email = String(row.email || '').trim();
    const lower = email.toLowerCase();

    if (!EMAIL_RE.test(email)) { rejected.push({ email: email, reason: 'invalid syntax' }); continue; }
    if (seen.has(lower)) { rejected.push({ email: email, reason: 'duplicate' }); continue; }
    seen.add(lower);
    if (suppressed.has(lower)) { rejected.push({ email: email, reason: 'already suppressed' }); continue; }

    const domain = lower.split('@')[1];
    if (allowed.length && allowed.indexOf(domain) < 0) { rejected.push({ email: email, reason: 'domain outside the authorised scope (add the exact host ' + domain + ' to allowedDomains)' }); continue; }

    const local = lower.split('@')[0];
    if (!opts.allowRole && ROLE_LOCALS.has(local)) { rejected.push({ email: email, reason: 'role account' }); continue; }

    if (!opts.noMxCheck) {
      if (!domainCache.has(domain)) domainCache.set(domain, await domainAcceptsMail(domain));
      const mail = domainCache.get(domain);
      if (!mail.ok) { rejected.push({ email: email, reason: 'domain has no MX or A record (' + domain + ')' }); continue; }
    }

    kept.push({ email: email, name: row.name || '', extra: row.extra || {} });
  }

  return { kept: kept, rejected: rejected, domains: Object.fromEntries(domainCache) };
}

function toCsv(rows) {
  const keys = [];
  for (const row of rows) for (const key of Object.keys(row.extra || {})) if (keys.indexOf(key) < 0) keys.push(key);
  const head = ['email', 'name'].concat(keys);
  const lines = [head.join(',')];
  for (const row of rows) {
    const cells = [row.email, row.name || ''];
    for (const key of keys) cells.push((row.extra && row.extra[key]) || '');
    lines.push(cells.map(function (c) {
      const value = String(c);
      return /[",\n]/.test(value) ? '"' + value.replace(/"/g, '""') + '"' : value;
    }).join(','));
  }
  return lines.join('\n') + '\n';
}

async function main() {
  const args = parseArgs(process.argv);
  if (!args.input) { console.error('usage: node tools/filter-leads.mjs --input <file> --out <file> [--domains a,b]'); process.exit(2); }

  const raw = await readFile(args.input, 'utf8');
  const rows = parseList(raw, 'auto');

  let suppressed = [];
  if (args.suppressed && existsSync(args.suppressed)) {
    try {
      const data = JSON.parse(readFileSync(args.suppressed, 'utf8').replace(/^\uFEFF/, ''));
      suppressed = Array.isArray(data.Suppressed) ? data.Suppressed : (Array.isArray(data.suppressed) ? data.suppressed : []);
    } catch (error) { void error; }
  }

  const result = await filterRows(rows, { domains: args.domains, suppressed: suppressed, allowRole: args.allowRole, noMxCheck: args.noMxCheck });

  if (args.out) {
    await mkdir(dirname(resolve(args.out)), { recursive: true });
    await writeFile(args.out, toCsv(result.kept), 'utf8');
  }
  if (args.rejected) {
    await mkdir(dirname(resolve(args.rejected)), { recursive: true });
    await writeFile(args.rejected, toCsv(result.rejected), 'utf8');
  }

  console.log('read      : ' + rows.length);
  console.log('kept      : ' + result.kept.length);
  console.log('rejected  : ' + result.rejected.length);
  const reasons = {};
  for (const r of result.rejected) reasons[r.reason] = (reasons[r.reason] || 0) + 1;
  for (const reason of Object.keys(reasons)) console.log('  - ' + reason + ': ' + reasons[reason]);
  console.log('domains   : ' + JSON.stringify(result.domains));
}

if (process.argv[1] && process.argv[1].endsWith('filter-leads.mjs')) {
  main().catch(function (error) { console.error(String((error && error.message) || error)); process.exit(1); });
}
