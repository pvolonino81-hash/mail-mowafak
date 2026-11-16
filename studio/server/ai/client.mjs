import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

export const DEFAULT_BASE_URL = 'https://agent.minimax.io/mavis/api/v1/llm/v1';
export const DEFAULT_MODEL = 'MiniMax-M3.1-Flash';

export function parseSimpleYaml(text) {
  const root = {};
  const stack = [{ indent: -1, node: root }];
  const lines = String(text || '').split(/\r?\n/);

  for (const raw of lines) {
    if (!raw.trim()) continue;
    if (raw.trim().startsWith('#')) continue;
    const indent = raw.length - raw.trimStart().length;
    const line = raw.trim();
    if (line.startsWith('- ')) continue;

    const match = line.match(/^([^:]+):\s*(.*)$/);
    if (!match) continue;

    const key = match[1].trim().replace(/^["']|["']$/g, '');
    let value = match[2].trim();

    while (stack.length > 1 && indent <= stack[stack.length - 1].indent) stack.pop();
    const parent = stack[stack.length - 1].node;

    if (value === '') {
      const node = {};
      parent[key] = node;
      stack.push({ indent: indent, node: node });
    } else {
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      parent[key] = value;
    }
  }
  return root;
}

export async function readMcodeToken(profileDir) {
  const dir = profileDir || process.env.USERPROFILE || process.env.HOME || '';
  if (!dir) return null;
  const file = join(dir, '.minimax', 'auth', 'prod', 'en', 'mcode-public', 'auth.json');
  let auth;
  try {
    auth = JSON.parse((await readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
  } catch {
    return null;
  }
  const records = auth && auth.records ? Object.values(auth.records) : [];
  for (const record of records) {
    if (record && record.accessToken) {
      return {
        token: String(record.accessToken),
        expiresAtMs: Number(record.expiresAtMs || 0),
        audience: String(record.audience || '')
      };
    }
  }
  return null;
}

export async function resolveAiCredentials(options) {
  const opts = options || {};
  const settings = opts.settings || {};
  const profileDir = opts.profileDir || process.env.USERPROFILE || process.env.HOME || '';

  let model = DEFAULT_MODEL;
  let baseUrl = DEFAULT_BASE_URL;
  let yamlKey = '';
  if (profileDir) {
    try {
      const yaml = parseSimpleYaml(await readFile(join(profileDir, '.minimax', 'config.yaml'), 'utf8'));
      const provider = (yaml.provider && yaml.provider.minimax) || {};
      const providerOptions = provider.options || {};
      if (providerOptions.baseURL) baseUrl = providerOptions.baseURL;
      if (providerOptions.apiKey) yamlKey = String(providerOptions.apiKey);
      const rawModel = String(yaml.defaultModel || '');
      if (rawModel) model = rawModel.includes('/') ? rawModel.split('/').pop() : rawModel;
    } catch {
      /* the profile is optional */
    }
  }

  if (settings.aiKey && String(settings.aiKey).trim()) {
    return {
      apiKey: String(settings.aiKey).trim(),
      baseUrl: settings.aiBaseUrl || baseUrl,
      model: settings.aiModel || model,
      source: 'settings'
    };
  }

  if (yamlKey && yamlKey.length > 20 && !/^sk-xxx$/i.test(yamlKey)) {
    return { apiKey: yamlKey, baseUrl: baseUrl, model: model, source: 'profile' };
  }

  const mcode = await readMcodeToken(profileDir);
  if (mcode) {
    const expired = mcode.expiresAtMs > 0 && mcode.expiresAtMs < Date.now();
    return {
      apiKey: mcode.token,
      baseUrl: baseUrl,
      model: model,
      source: expired ? 'mcode-expired' : 'mcode',
      expiresAtMs: mcode.expiresAtMs
    };
  }

  return { apiKey: '', baseUrl: baseUrl, model: model, source: 'none' };
}

function extractText(data) {
  if (Array.isArray(data && data.content)) {
    const text = data.content.filter(function (p) { return p && p.type === 'text'; })
      .map(function (p) { return p.text; }).join('\n');
    if (text) return text;
  }
  if (data && data.choices && data.choices[0] && data.choices[0].message) {
    return String(data.choices[0].message.content || '');
  }
  if (typeof (data && data.content) === 'string') return data.content;
  return '';
}

export async function callMiniMax(input) {
  const opts = input || {};
  if (!opts.apiKey) throw new Error('no MiniMax credential available');

  const baseUrl = String(opts.baseUrl || DEFAULT_BASE_URL).replace(/\/+$/, '');
  const url = baseUrl + '/messages';
  const controller = new AbortController();
  const timer = setTimeout(function () { controller.abort(); }, opts.timeoutMs || 60000);

  try {
    const res = await fetch(url, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        'Authorization': 'Bearer ' + opts.apiKey
      },
      body: JSON.stringify({
        model: opts.model || DEFAULT_MODEL,
        max_tokens: opts.maxTokens || 1200,
        system: opts.system || '',
        messages: [{ role: 'user', content: String(opts.prompt || '') }]
      })
    });

    const text = await res.text();
    if (!res.ok) throw new Error('MiniMax ' + res.status + ': ' + text.slice(0, 400));

    let data;
    try { data = JSON.parse(text); } catch { throw new Error('MiniMax returned a non-JSON body'); }

    const out = extractText(data);
    if (!out) throw new Error('MiniMax returned no text');
    return out;
  } finally {
    clearTimeout(timer);
  }
}
