import { mkdir, readFile, writeFile, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function isValidEmail(value) {
  return EMAIL_RE.test(String(value || '').trim());
}

export function splitRow(line, delimiter) {
  const parts = [];
  let current = '';
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '"') { quoted = !quoted; continue; }
    if (ch === delimiter && !quoted) { parts.push(current); current = ''; continue; }
    current += ch;
  }
  parts.push(current);
  return parts.map(function (p) { return p.trim(); });
}

export function importList(text, options) {
  const opts = options || {};
  const format = opts.format || 'auto';
  const raw = String(text || '');
  const lines = raw.split(/\r?\n/).filter(function (l) { return l.trim() && !l.trim().startsWith('#'); });
  if (lines.length === 0) return { rows: [], skipped: [] };

  let delimiter = opts.delimiter || ',';
  let header = null;
  let body = lines;

  const looksCsv = lines[0].includes(',') || lines[0].includes(';') || lines[0].includes('\t');
  if (format === 'auto') {
    if (looksCsv) {
      delimiter = lines[0].includes(';') && !lines[0].includes(',') ? ';' : (lines[0].includes('\t') ? '\t' : ',');
    } else {
      format = 'txt';
    }
  }

  if (format === 'csv' || format === 'tsv') {
    if (format === 'tsv') delimiter = '\t';
    const first = splitRow(lines[0], delimiter).map(function (c) { return c.toLowerCase(); });
    if (first.indexOf('email') >= 0 || first.indexOf('e-mail') >= 0) {
      header = first;
      body = lines.slice(1);
    }
  }

  const rows = [];
  const skipped = [];
  for (const line of body) {
    if (format === 'txt') {
      const comma = line.indexOf(',');
      const email = (comma >= 0 ? line.slice(0, comma) : line).trim();
      const name = comma >= 0 ? line.slice(comma + 1).trim() : '';
      if (!isValidEmail(email)) { skipped.push({ line: line, reason: 'invalid email' }); continue; }
      rows.push({ email: email.toLowerCase(), name: name, extra: {} });
      continue;
    }
    const cells = splitRow(line, delimiter);
    let email = '';
    let name = '';
    const extra = {};
    if (header) {
      for (let i = 0; i < cells.length; i += 1) {
        const key = header[i] || ('col' + i);
        const value = cells[i];
        if (key === 'email' || key === 'e-mail') email = value;
        else if (key === 'name' || key === 'full_name' || key === 'customer_name') name = value;
        else extra[key] = value;
      }
    } else {
      email = cells[0] || '';
      name = cells[1] || '';
      for (let i = 2; i < cells.length; i += 1) extra['col' + i] = cells[i];
    }
    if (!isValidEmail(email)) { skipped.push({ line: line, reason: 'invalid email' }); continue; }
    rows.push({ email: email.toLowerCase(), name: name, extra: extra });
  }
  return { rows: rows, skipped: skipped };
}

export function dedupe(rows) {
  const seen = new Set();
  const kept = [];
  const duplicates = [];
  for (const row of rows) {
    const key = String(row.email || '').trim().toLowerCase();
    if (!key) continue;
    if (seen.has(key)) { duplicates.push(row); continue; }
    seen.add(key);
    kept.push(row);
  }
  return { rows: kept, duplicates: duplicates };
}

export function validate(rows) {
  const valid = [];
  const invalid = [];
  for (const row of rows) {
    if (isValidEmail(row.email)) valid.push(row);
    else invalid.push(row);
  }
  return { rows: valid, invalid: invalid };
}

export function exportList(rows, format) {
  const kind = format || 'csv';
  if (kind === 'txt') {
    return rows.map(function (r) {
      return r.name ? (r.email + ',' + r.name) : r.email;
    }).join('\n') + '\n';
  }
  const keys = [];
  for (const row of rows) {
    for (const key of Object.keys(row.extra || {})) {
      if (keys.indexOf(key) < 0) keys.push(key);
    }
  }
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

export async function saveList(dataDir, id, payload) {
  const dir = join(dataDir, 'lists');
  await mkdir(dir, { recursive: true });
  const file = join(dir, id + '.json');
  const tmp = file + '.tmp';
  await writeFile(tmp, JSON.stringify(payload, null, 2), 'utf8');
  const { rename } = await import('node:fs/promises');
  await rename(tmp, file);
  return file;
}

export async function loadList(dataDir, id) {
  const file = join(dataDir, 'lists', id + '.json');
  if (!existsSync(file)) return null;
  const raw = await readFile(file, 'utf8');
  return JSON.parse(raw.replace(/^\uFEFF/, ''));
}

export async function listListIds(dataDir) {
  const dir = join(dataDir, 'lists');
  if (!existsSync(dir)) return [];
  const entries = await readdir(dir);
  return entries.filter(function (f) { return f.endsWith('.json'); }).map(function (f) { return f.replace(/\.json$/, ''); });
}
