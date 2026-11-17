// build-recipient-list.mjs - turns a raw lead list into the engine's CSV format.
//
// The engine reads a CSV where the first column is "email" and derives
// {{first_name}} from the first word of "name". For a mailbox-only list there is
// no real first name, so the display name is derived from the mailbox handle
// itself (digits dropped, first letter capitalised). Nothing is invented.
//
// Usage:
//   node tools/build-recipient-list.mjs --input data/leads/raw.csv --out data/leads/engine.csv

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

function splitRow(line) {
  const cells = [];
  let current = '';
  let quoted = false;
  for (const ch of line) {
    if (ch === '"') { quoted = !quoted; continue; }
    if (ch === ',' && !quoted) { cells.push(current.trim()); current = ''; continue; }
    current += ch;
  }
  cells.push(current.trim());
  return cells;
}

export function displayName(local) {
  let s = String(local || '').trim();
  s = s.replace(/^[0-9]+/, '').replace(/[0-9]+$/, '');
  s = s.replace(/[._-]+/g, ' ').trim();
  if (!s) return 'Customer';
  s = s.charAt(0).toUpperCase() + s.slice(1);
  if (!/^[A-Za-z][A-Za-z\s'-]{1,30}$/.test(s)) return 'Customer';
  return s;
}

const input = arg('--input', '');
const out = arg('--out', '');
const segment = arg('--segment', 'drill');
if (!input || !out) {
  console.error('usage: build-recipient-list.mjs --input <file> --out <file>');
  process.exit(2);
}

const text = await readFile(input, 'utf8');
const lines = text.split(/\r?\n/).filter(l => l.trim());
const seen = new Set();
const rows = [];
for (const line of lines) {
  const cells = splitRow(line);
  const email = (cells[0] || '').replace(/^<|>$/g, '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$/.test(email)) continue;
  if (seen.has(email)) continue;
  seen.add(email);
  const local = email.split('@')[0];
  const handle = local;
  rows.push({
    email: email,
    name: displayName(local),
    handle: handle,
    segment: segment
  });
}

const esc = v => '"' + String(v).replace(/"/g, '""') + '"';
const csv = ['email,name,handle,segment']
  .concat(rows.map(r => [esc(r.email), esc(r.name), esc(r.handle), esc(r.segment)].join(',')))
  .join('\n') + '\n';

await mkdir(dirname(out), { recursive: true });
await writeFile(out, csv, 'utf8');
console.log('read    : ' + lines.length);
console.log('written : ' + rows.length);
console.log('out     : ' + out);
