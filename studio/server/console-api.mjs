import { existsSync, readFileSync, readdirSync, statSync, openSync, readSync, closeSync } from 'node:fs';
import { join } from 'node:path';

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    return null;
  }
}

function pick(obj, names, fallback) {
  for (const name of names) {
    if (obj && obj[name] !== undefined && obj[name] !== null) return obj[name];
  }
  return fallback;
}

export function normalizeReport(report) {
  if (!report) return null;
  const totals = report.totals || report.Totals || {};
  const perVariant = (report.perVariant || report.PerVariant || []).map(function (v) {
    return {
      Variant: String(pick(v, ['Variant', 'variant', 'id'], '')),
      Sent: Number(pick(v, ['Sent', 'sent'], 0)),
      Failed: Number(pick(v, ['Failed', 'failed'], 0)),
      Skipped: Number(pick(v, ['Skipped', 'skipped'], 0)),
      Total: Number(pick(v, ['Total', 'total'], 0))
    };
  });
  const perIp = (report.perIp || report.PerIp || report.egress || []).map(function (r) {
    return {
      EgressIp: String(pick(r, ['EgressIp', 'egressIp', 'ip', 'Ip'], '')),
      Sent: Number(pick(r, ['Sent', 'sent'], 0)),
      Failed: Number(pick(r, ['Failed', 'failed'], 0))
    };
  });
  const rotations = (report.rotations || report.Rotations || []).map(function (r) {
    return {
      rotationIndex: pick(r, ['rotationIndex', 'RotationIndex'], ''),
      egressIp: String(pick(r, ['egressIp', 'EgressIp'], '')),
      sessionId: String(pick(r, ['sessionId', 'SessionId'], '')),
      previousIp: String(pick(r, ['previousIp', 'PreviousIp'], ''))
    };
  });
  return {
    totals: {
      sent: Number(pick(totals, ['sent', 'Sent'], 0)),
      failed: Number(pick(totals, ['failed', 'Failed'], 0)),
      skipped: Number(pick(totals, ['skipped', 'Skipped'], 0)),
      rotations: Number(pick(totals, ['rotations', 'Rotations'], 0)),
      batches: Number(pick(totals, ['batches', 'Batches'], 0))
    },
    perVariant: perVariant,
    perIp: perIp,
    rotations: rotations
  };
}

export function createLiveReader() {
  const state = { file: '', offset: 0, totals: null, ip: '', variant: '' };

  function reset(file) {
    state.file = file;
    state.offset = 0;
    state.totals = { sent: 0, failed: 0, skipped: 0, rotations: 0, batches: 0, messages: 0 };
    state.ip = '';
    state.variant = '';
  }

  function newestRun(logsDir) {
    try {
      const names = readdirSync(logsDir).filter(function (n) { return /^run-.*\.jsonl$/i.test(n); });
      if (!names.length) return '';
      let best = '';
      let bestTime = 0;
      for (const name of names) {
        const info = statSync(join(logsDir, name));
        if (info.mtimeMs >= bestTime) { bestTime = info.mtimeMs; best = name; }
      }
      return join(logsDir, best);
    } catch {
      return '';
    }
  }

  function read(logsDir) {
    if (!logsDir || !existsSync(logsDir)) return null;
    const file = newestRun(logsDir);
    if (!file) return null;
    if (file !== state.file) reset(file);

    try {
      const size = statSync(file).size;
      if (size > state.offset) {
        const fd = openSync(file, 'r');
        const buffer = Buffer.alloc(size - state.offset);
        readSync(fd, buffer, 0, buffer.length, state.offset);
        closeSync(fd);
        state.offset = size;
        for (const line of buffer.toString('utf8').split(/\r?\n/)) {
          if (!line.trim()) continue;
          let record = null;
          try { record = JSON.parse(line); } catch (error) { void error; }
          if (!record) continue;
          const msg = String(record.msg || '');
          if (msg.startsWith('sent ')) state.totals.sent += 1;
          else if (msg.startsWith('failed ')) state.totals.failed += 1;
          else if (msg.startsWith('Rotated egress IP ->')) {
            state.totals.rotations += 1;
            state.ip = msg.slice('Rotated egress IP ->'.length).split(' ')[0].trim();
          } else if (msg.startsWith('Creative rotated -> variant')) {
            const m = msg.match(/variant '([^']+)'/);
            if (m) state.variant = m[1];
          } else if (msg.startsWith('Batch ')) state.totals.batches += 1;
          else if (msg.startsWith('Skipped ')) {
            const m = msg.match(/Skipped (\d+) recipient/);
            if (m) state.totals.skipped += Number(m[1]);
          }
          state.totals.messages += 1;
        }
      }
    } catch (error) { void error; }

    return {
      runFile: state.file ? state.file.split(/[\\/]/).pop() : '',
      totals: state.totals,
      currentIp: state.ip,
      currentVariant: state.variant
    };
  }

  return { read: read };
}

export function readCheckpoint(engineRoot) {
  const file = join(engineRoot, 'state', 'checkpoint.json');
  if (!existsSync(file)) return null;
  const data = readJson(file);
  if (!data) return null;
  return {
    sentCount: Number(data.SentCount ?? 0),
    failedCount: Number(data.FailedCount ?? 0),
    batchIndex: Number(data.BatchIndex ?? 0),
    rotations: Number(data.Rotations ?? 0),
    processed: Array.isArray(data.Processed) ? data.Processed.length : 0,
    savedAtUtc: String(data.SavedAtUtc ?? '')
  };
}

export function readSuppressed(engineRoot) {
  const file = join(engineRoot, 'state', 'suppressed.json');
  if (!existsSync(file)) return [];
  const data = readJson(file);
  if (!data) return [];
  return Array.isArray(data.Suppressed) ? data.Suppressed : [];
}

export function listRecentRuns(engineRoot) {
  const dir = join(engineRoot, 'logs');
  if (!existsSync(dir)) return [];
  const items = [];
  for (const name of readdirSync(dir)) {
    if (!/^run-.*\.jsonl$/i.test(name)) continue;
    try {
      const info = statSync(join(dir, name));
      items.push({ file: name, modifiedAt: info.mtime.toISOString(), bytes: info.size });
    } catch (error) { void error; }
  }
  items.sort(function (a, b) { return a.modifiedAt < b.modifiedAt ? 1 : -1; });
  return items.slice(0, 25);
}

export function readLatestReportFile(engineRoot) {
  const dir = join(engineRoot, 'logs');
  if (!existsSync(dir)) return null;
  const names = readdirSync(dir).filter(function (n) { return /^report-.*\.json$/i.test(n); }).sort();
  if (!names.length) return null;
  const file = join(dir, names[names.length - 1]);
  return { file: names[names.length - 1], report: normalizeReport(readJson(file)) };
}

export function readProduct(engineRoot) {
  const file = join(engineRoot, 'assets', 'product.json');
  const data = readJson(file);
  if (!data) return { name: 'MAIL MOWAFAK', owner: '', tagline: '', version: '', locked: true };
  return data;
}

export function readConfigView(engineRoot) {
  const data = readJson(join(engineRoot, 'config', 'config.json'));
  if (!data) return null;
  const smtp = data.smtp || {};
  const message = data.message || {};
  const batch = data.batch || {};
  const proxy = data.proxy || {};
  return {
    smtpHost: String(smtp.host || ''),
    smtpUser: String(smtp.username || ''),
    smtpProvider: String(smtp.provider || ''),
    batchSize: Number(batch.size || 0),
    creativeRotateEvery: Number(message.rotateEvery || 0),
    proxyMode: String(proxy.mode || ''),
    consentBasis: String(data.consentBasis || ''),
    allowedDomains: Array.isArray(message.allowedDomains) ? message.allowedDomains : []
  };
}
