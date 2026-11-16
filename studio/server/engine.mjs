import { existsSync } from 'node:fs';
import { join } from 'node:path';

export function isEngineRoot(dir) {
  if (!dir) return false;
  try {
    return existsSync(join(dir, 'Send-Mail.ps1')) && existsSync(join(dir, 'config', 'config.json'));
  } catch {
    return false;
  }
}

export function resolveEngine(settings) {
  const candidates = [];
  if (settings && settings.projectPath) candidates.push(settings.projectPath);
  for (const dir of candidates) {
    if (isEngineRoot(dir)) return dir;
  }
  return null;
}

export function enginePaths(root) {
  return {
    root: root,
    sendScript: join(root, 'Send-Mail.ps1'),
    config: join(root, 'config', 'config.json'),
    clients: join(root, 'clients'),
    data: join(root, 'data'),
    logs: join(root, 'logs'),
    state: join(root, 'state')
  };
}
