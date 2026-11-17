// campaign-watcher.mjs - keeps the campaign moving while the provider is throttling.
//
// It probes the relay with a single real message every few minutes. When the
// relay accepts one, it hands the whole remaining list to the studio (which
// runs the engine with the AI Doctor watching) and exits.
//
// The mailbox password is read from the process environment only. It is never
// written to disk and never printed.
//
// Usage:
//   $env:OPTONLINE_SMTP_PASSWORD = '...'; node tools/campaign-watcher.mjs --interval 900

import { spawn } from 'node:child_process';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const studioUrl = arg('--studio', 'http://127.0.0.1:8931');
const engineRoot = arg('--engine', join(process.cwd(), 'MailRotatorStudio', 'engine'));
const clientId = arg('--client', 'ups-trial');
const recipients = arg('--recipients', 'data/leads/10KCFL-remaining.csv');
const intervalMs = Number(arg('--interval', '900')) * 1000;
const maxAttempts = Number(arg('--attempts', '80'));
const burst = Number(arg('--burst', '50'));
const logFile = arg('--log', join(engineRoot, 'logs', 'ups-trial', 'watcher.log'));
const password = process.env.OPTONLINE_SMTP_PASSWORD || '';

function log(line) {
  const stamp = new Date().toISOString();
  const text = stamp + '  ' + line;
  console.log(text);
  return writeFile(logFile, text + '\n', { flag: 'a' }).catch(function () {});
}

async function api(path, body) {
  const res = await fetch(studioUrl + path, {
    method: body ? 'POST' : 'GET',
    headers: { 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  return res.json();
}

async function newestRunLog() {
  const dir = join(engineRoot, 'logs', 'ups-trial');
  let names = [];
  try { names = await readdir(dir); } catch (e) { return null; }
  const runs = names.filter(function (n) { return /^run-.*\.jsonl$/.test(n); }).sort();
  if (!runs.length) return null;
  return join(dir, runs[runs.length - 1]);
}

async function lastRunSummary() {
  const file = await newestRunLog();
  if (!file) return { sent: 0, failed: 0, blocked: false };
  const text = await readFile(file, 'utf8');
  const lines = text.split(/\r?\n/).filter(Boolean);
  let sent = 0, failed = 0, blocked = false;
  for (const line of lines) {
    if (line.indexOf('"msg":"sent ') >= 0) sent += 1;
    else if (line.indexOf('"msg":"failed ') >= 0) failed += 1;
    if (line.indexOf('Resources restricted') >= 0 || line.indexOf('4.7.1') >= 0 || line.indexOf('5.5.3') >= 0) blocked = true;
  }
  return { sent: sent, failed: failed, blocked: blocked, file: file };
}

async function waitForIdle() {
  for (let i = 0; i < 600; i += 1) {
    const state = await api('/api/state').catch(function () { return null; });
    if (state && state.job && state.job.running === false) return state;
    await new Promise(function (r) { setTimeout(r, 2000); });
  }
  return null;
}

async function main() {
  if (!password) { log('FATAL: OPTONLINE_SMTP_PASSWORD is not set in the environment.'); process.exit(2); }
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    await log('attempt ' + attempt + '/' + maxAttempts + ' — probing the relay with one message');
    await api('/api/run', { mode: 'send', clientId: clientId, recipientsPath: recipients, maxMessages: 1, smtpPassword: password });
    await waitForIdle();
    const summary = await lastRunSummary();
    await log('probe result: sent=' + summary.sent + ' failed=' + summary.failed + ' blocked=' + summary.blocked);
    if (summary.sent > 0) {
      await log('relay accepted a message — launching the full remaining list');
      const r = await api('/api/run', { mode: 'send', clientId: clientId, recipientsPath: recipients, maxMessages: burst, smtpPassword: password });
      await log('burst launched (' + burst + ' messages): ' + JSON.stringify(r).slice(0, 200));
      process.exit(0);
    }
    await log('relay still refusing — waiting ' + Math.round(intervalMs / 1000) + 's');
    await new Promise(function (r) { setTimeout(r, intervalMs); });
  }
  await log('giving up after ' + maxAttempts + ' attempts');
  process.exit(1);
}

main();
