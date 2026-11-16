import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { dirname, join } from 'node:path';

export const DEFAULT_SETTINGS = {
  projectPath: '',
  aiKey: '',
  aiModel: '',
  aiBaseUrl: '',
  collectorUrl: '',
  collectorKey: '',
  port: 0
};

export async function loadSettings(dataDir) {
  const file = join(dataDir, 'settings.json');
  let stored = {};
  try {
    const raw = await readFile(file, 'utf8');
    stored = JSON.parse(raw.replace(/^\uFEFF/, ''));
    if (!stored || typeof stored !== 'object') stored = {};
  } catch {
    stored = {};
  }

  const settings = Object.assign({}, DEFAULT_SETTINGS, stored);

  async function save(patch) {
    const next = Object.assign({}, settings, patch || {});
    await mkdir(dirname(file), { recursive: true });
    const tmp = file + '.tmp';
    await writeFile(tmp, JSON.stringify(next, null, 2), 'utf8');
    await rename(tmp, file);
    Object.assign(settings, next);
    return Object.assign({}, settings);
  }

  return {
    file: file,
    settings: settings,
    save: save,
    get: function () { return Object.assign({}, settings); }
  };
}
