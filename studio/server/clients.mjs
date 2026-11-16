import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

export async function listClients(engineRoot) {
  const dir = join(engineRoot, 'clients');
  const out = [];
  if (!existsSync(dir)) return out;

  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isDirectory()) {
      const file = join(dir, entry.name, 'client.json');
      if (existsSync(file)) {
        const profile = await readProfile(file, entry.name);
        if (profile) out.push(profile);
      }
    } else if (entry.isFile() && entry.name.endsWith('.json')) {
      const profile = await readProfile(join(dir, entry.name), entry.name.replace(/\.json$/, ''));
      if (profile) out.push(profile);
    }
  }
  return out.sort(function (a, b) { return String(a.id).localeCompare(String(b.id)); });
}

async function readProfile(file, fallbackId) {
  try {
    const raw = await readFile(file, 'utf8');
    const data = JSON.parse(raw.replace(/^\uFEFF/, ''));
    return {
      id: String(data.id || fallbackId),
      name: String(data.name || fallbackId),
      path: file,
      data: data
    };
  } catch {
    return null;
  }
}

export async function readClient(engineRoot, id) {
  const all = await listClients(engineRoot);
  const found = all.find(function (c) { return c.id === id; });
  return found || null;
}

export async function writeClient(engineRoot, id, data) {
  const dir = join(engineRoot, 'clients', id);
  await mkdir(dir, { recursive: true });
  const file = join(dir, 'client.json');
  const payload = Object.assign({}, data, { id: id });
  const tmp = file + '.tmp';
  await writeFile(tmp, JSON.stringify(payload, null, 2), 'utf8');
  const { rename } = await import('node:fs/promises');
  await rename(tmp, file);
  return { id: id, path: file, data: payload };
}
