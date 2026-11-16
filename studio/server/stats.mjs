import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

export async function readLatestReport(engineRoot, clientId) {
  const logs = join(engineRoot, 'logs');
  if (!existsSync(logs)) return null;
  const entries = await readdir(logs, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (entry.isDirectory() && clientId && entry.name === clientId) {
      const inner = await readdir(join(logs, clientId));
      for (const f of inner) if (f.startsWith('report-') && f.endsWith('.json')) files.push(join(logs, clientId, f));
    } else if (entry.isFile() && entry.name.startsWith('report-') && entry.name.endsWith('.json')) {
      files.push(join(logs, entry.name));
    }
  }
  if (files.length === 0) return null;
  files.sort();
  const file = files[files.length - 1];
  const raw = await readFile(file, 'utf8');
  return { file: file, report: JSON.parse(raw.replace(/^\uFEFF/, '')) };
}

export function summarize(report) {
  if (!report) return null;
  const totals = report.totals || {};
  const sent = Number(totals.sent || 0);
  const failed = Number(totals.failed || 0);
  const skipped = Number(totals.skipped || 0);
  const attempts = sent + failed + skipped;
  return {
    sent: sent,
    failed: failed,
    skipped: skipped,
    batches: Number(totals.batches || 0),
    perVariant: report.perVariant || report.variants || [],
    perIp: report.perIp || report.egress || [],
    failureRate: attempts ? failed / attempts : 0,
    skipRate: attempts ? skipped / attempts : 0
  };
}

export async function fetchCollectorStats(options) {
  const opts = options || {};
  if (!opts.baseUrl || !opts.key) return null;
  const url = String(opts.baseUrl).replace(/\/+$/, '') + '/stats.php?key=' + encodeURIComponent(opts.key) + (opts.clientId ? '&client=' + encodeURIComponent(opts.clientId) : '');
  const res = await fetch(url, { signal: AbortSignal.timeout(15000) });
  if (!res.ok) throw new Error('collector returned ' + res.status);
  const data = await res.json();
  const opens = Number(data.opens || 0);
  const clicks = Number(data.clicks || 0);
  const delivered = Number(data.delivered || 0);
  return {
    opens: opens,
    clicks: clicks,
    delivered: delivered,
    openRate: delivered ? opens / delivered : 0,
    clickRate: delivered ? clicks / delivered : 0,
    clickToOpenRate: opens ? clicks / opens : 0
  };
}
