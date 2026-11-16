import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { extname, join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadSettings } from './config.mjs';
import { resolveEngine, isEngineRoot } from './engine.mjs';
import { createSession } from './session.mjs';
import { listClients, readClient, writeClient } from './clients.mjs';
import { importList, dedupe, validate, exportList, saveList, listListIds, loadList } from './lists.mjs';
import { readLatestReport, summarize, fetchCollectorStats } from './stats.mjs';
import { resolveAiCredentials, callMiniMax } from './ai/client.mjs';
import {
  createLiveReader, normalizeReport, readCheckpoint, readSuppressed,
  listRecentRuns, readLatestReportFile, readConfigView, readProduct
} from './console-api.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const uiDir = join(here, '..', 'ui');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml'
};

function sendJson(res, code, payload) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(payload));
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw.trim()) return {};
  try { return JSON.parse(raw); } catch { return {}; }
}

export async function createApp(options) {
  const opts = options || {};
  const dataDir = opts.dataDir;
  const store = await loadSettings(dataDir);
  const liveReader = createLiveReader();
  let aiCredentials = await resolveAiCredentials({ settings: store.settings });
  let session = null;

  function buildSession(engineRoot) {
    return createSession({
      engineRoot: engineRoot,
      clientId: 'console',
      ai: {
        call: async function (input) {
          return callMiniMax({
            apiKey: aiCredentials.apiKey,
            baseUrl: aiCredentials.baseUrl,
            model: aiCredentials.model,
            system: input.system,
            prompt: input.prompt
          });
        }
      }
    });
  }

  function setProject(engineRoot) {
    if (session) session.stop('the project changed');
    session = engineRoot ? buildSession(engineRoot) : null;
    return session;
  }

  const settingsPath = store.settings.projectPath;
  if (settingsPath && isEngineRoot(settingsPath)) setProject(settingsPath);
  else if (opts.engineRoot && isEngineRoot(opts.engineRoot)) setProject(opts.engineRoot);

  function engineRoot() {
    return session ? session.engineRoot : '';
  }

  function snapshot() {
    const root = engineRoot();
    const configured = !!root && isEngineRoot(root);
    const job = session ? session.jobInfo() : { running: false, stopped: false, exitCode: null, mode: '', startedAt: '', maxMessages: 0, output: [] };
    return {
      project: {
        configured: configured,
        projectPath: root,
        reason: configured ? '' : 'حدّد مجلد المشروع الذي يحتوي Send-Mail.ps1 و config/config.json.'
      },
      config: configured ? readConfigView(root) : null,
      live: configured ? liveReader.read(join(root, 'logs')) : null,
      latestReport: configured ? (readLatestReportFile(root) || {}).report || null : null,
      job: job,
      checkpoint: configured ? readCheckpoint(root) : null,
      recentRuns: configured ? listRecentRuns(root) : [],
      suppressedCount: configured ? readSuppressed(root).length : 0,
      ai: {
        source: aiCredentials.source,
        model: aiCredentials.model,
        ready: !!aiCredentials.apiKey,
        decisions: session ? session.doctor.decisions.length : 0
      }
    };
  }

  const server = createServer(async function (req, res) {
    const url = new URL(req.url, 'http://127.0.0.1');
    const path = url.pathname;
    const method = req.method;

    try {
      if (path === '/api/product' && method === 'GET') {
        sendJson(res, 200, { ok: true, product: readProduct(engineRoot()) });
        return;
      }

      if (path === '/api/health') {
        sendJson(res, 200, {
          ok: true,
          version: '0.1.0',
          engineRoot: engineRoot(),
          product: readProduct(engineRoot()),
          ai: { source: aiCredentials.source, model: aiCredentials.model, ready: !!aiCredentials.apiKey }
        });
        return;
      }

      if (path === '/api/state' && method === 'GET') {
        sendJson(res, 200, snapshot());
        return;
      }

      if (path === '/api/diagnostic' && method === 'GET') {
        const root = engineRoot();
        sendJson(res, 200, {
          ok: true,
          project: root,
          engine: root ? isEngineRoot(root) : false,
          ai: aiCredentials,
          decisions: session ? session.doctor.decisions : []
        });
        return;
      }

      if (path === '/api/suppressed' && method === 'GET') {
        sendJson(res, 200, { addresses: engineRoot() ? readSuppressed(engineRoot()) : [] });
        return;
      }

      if (path === '/api/report' && method === 'GET') {
        const root = engineRoot();
        const latest = root ? readLatestReportFile(root) : null;
        sendJson(res, latest ? 200 : 404, latest || { error: 'report_not_found' });
        return;
      }

      if (path === '/api/decisions' && method === 'GET') {
        sendJson(res, 200, { ok: true, decisions: session ? session.doctor.decisions : [] });
        return;
      }

      if (path === '/api/settings') {
        if (method === 'POST') {
          const body = await readBody(req);
          if (body.projectPath !== undefined) {
            const candidate = String(body.projectPath || '').trim();
            if (candidate && !isEngineRoot(candidate)) {
              sendJson(res, 400, { error: 'project_invalid', message: 'المجلد لا يحتوي Send-Mail.ps1 أو config/config.json' });
              return;
            }
            await store.save({ projectPath: candidate });
            setProject(candidate);
            aiCredentials = await resolveAiCredentials({ settings: store.get() });
          } else {
            await store.save(body);
            aiCredentials = await resolveAiCredentials({ settings: store.get() });
          }
          sendJson(res, 200, { ok: true, settings: store.get() });
          return;
        }
        sendJson(res, 200, { ok: true, settings: store.get() });
        return;
      }

      if (path === '/api/run' && method === 'POST') {
        const body = await readBody(req);
        if (!session) { sendJson(res, 400, { ok: false, error: 'no project selected' }); return; }
        const root = engineRoot();
        const recipients = body.recipientsPath
          ? resolve(root, String(body.recipientsPath))
          : join(root, 'data', 'recipients.csv');
        const configFile = body.configPath
          ? resolve(root, String(body.configPath))
          : join(root, 'config', 'config.json');
        const env = {};
        if (body.mode === 'send') {
          if (body.smtpPassword) env.OPTONLINE_SMTP_PASSWORD = String(body.smtpPassword);
          if (body.proxyPassword) env.NINEPROXY_PASSWORD = String(body.proxyPassword);
        }
        session.start({
          clientId: body.clientId || '',
          recipientsPath: recipients,
          configPath: configFile,
          dryRun: body.mode !== 'send',
          maxMessages: Number(body.maxMessages || 0),
          batchSize: Number(body.batchSize || 0),
          skipUrlChecks: !!body.skipUrlChecks,
          env: env
        });
        sendJson(res, 200, { ok: true, job: session.jobInfo() });
        return;
      }

      if (path === '/api/run/stop' && method === 'POST') {
        if (session) session.stop('stopped from the console');
        sendJson(res, 200, { ok: true });
        return;
      }

      if (path === '/api/clients' && method === 'GET') {
        if (!session) { sendJson(res, 400, { ok: false, error: 'no project selected' }); return; }
        const clients = await listClients(engineRoot());
        sendJson(res, 200, { ok: true, clients: clients.map(function (c) { return { id: c.id, name: c.name, path: c.path }; }) });
        return;
      }

      if (path.startsWith('/api/clients/') && method === 'POST') {
        if (!session) { sendJson(res, 400, { ok: false, error: 'no project selected' }); return; }
        const id = decodeURIComponent(path.replace('/api/clients/', ''));
        const body = await readBody(req);
        const saved = await writeClient(engineRoot(), id, body.data || body);
        sendJson(res, 200, { ok: true, client: { id: saved.id, path: saved.path } });
        return;
      }

      if (path === '/api/lists' && method === 'GET') {
        sendJson(res, 200, { ok: true, lists: await listListIds(dataDir) });
        return;
      }

      if (path === '/api/lists/import' && method === 'POST') {
        const body = await readBody(req);
        const parsed = importList(body.text || '', { format: body.format || 'auto' });
        const clean = dedupe(parsed.rows);
        const checked = validate(clean.rows);
        const id = body.id || ('list-' + Date.now());
        await saveList(dataDir, id, { id: id, createdAt: new Date().toISOString(), rows: checked.rows });
        sendJson(res, 200, {
          ok: true, id: id, imported: parsed.rows.length,
          duplicates: clean.duplicates.length, invalid: checked.invalid.length + parsed.skipped.length
        });
        return;
      }

      if (path === '/api/events') {
        res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store', connection: 'keep-alive' });
        res.write(': connected\n\n');
        const unsubscribe = session ? session.on(function (event) {
          res.write('data: ' + JSON.stringify(event) + '\n\n');
        }) : function () {};
        req.on('close', unsubscribe);
        return;
      }

      if (path === '/api/stats' && method === 'GET') {
        const root = engineRoot();
        const latest = root ? await readLatestReport(root, url.searchParams.get('client')) : null;
        let tracking = null;
        if (store.settings.collectorUrl) {
          try {
            tracking = await fetchCollectorStats({
              baseUrl: store.settings.collectorUrl,
              key: store.settings.collectorKey,
              clientId: url.searchParams.get('client')
            });
          } catch (error) {
            tracking = { error: String((error && error.message) || error) };
          }
        }
        sendJson(res, 200, { ok: true, report: summarize(latest ? latest.report : null), tracking: tracking });
        return;
      }

      if (method === 'GET' && existsSync(uiDir)) {
        let rel = path === '/' || path === '/dashboard' ? 'index.html' : path.replace(/^\//, '');
        if (rel.startsWith('assets/')) rel = rel;
        const file = join(uiDir, rel);
        if (existsSync(file)) {
          const body = await readFile(file);
          res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream' });
          res.end(body);
          return;
        }
      }

      sendJson(res, 404, { ok: false, error: 'not found' });
    } catch (error) {
      sendJson(res, 500, { ok: false, error: String((error && error.message) || error) });
    }
  });

  return {
    server: server,
    get session() { return session; },
    settings: store,
    get aiCredentials() { return aiCredentials; },
    start: function (port) {
      return new Promise(function (resolve) {
        server.listen(port || 0, '127.0.0.1', function () { resolve(server.address().port); });
      });
    },
    stop: function () {
      return new Promise(function (resolve) { server.close(function () { resolve(); }); });
    }
  };
}

if (process.argv[1] && process.argv[1].endsWith('index.mjs')) {
  const args = process.argv.slice(2);
  function argValue(name, fallback) {
    const index = args.indexOf(name);
    return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
  }
  const dataDir = argValue('--data', process.env.APPDATA || process.cwd());
  const engineRoot = argValue('--project', '');
  const app = await createApp({ dataDir: dataDir, engineRoot: engineRoot || null });
  const port = await app.start(Number(argValue('--port', '8931')));
  const url = 'http://127.0.0.1:' + port + '/dashboard';
  const cliRoot = app.session ? app.session.engineRoot : '';
  const product = readProduct(cliRoot);
  process.stdout.write(product.name + ' is running\n');
  process.stdout.write('  console : ' + url + '\n');
  process.stdout.write('  data    : ' + dataDir + '\n');
  process.stdout.write('  project : ' + (engineRoot || '(not set)') + '\n');
  if (process.env.STUDIO_OPEN === '1') {
    const { spawn } = await import('node:child_process');
    spawn('cmd', ['/c', 'start', '""', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  }
}
