import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync, readdirSync, statSync, openSync, readSync, closeSync } from 'node:fs';
import { join } from 'node:path';
import { enginePaths } from './engine.mjs';
import { runEngine } from './runner.mjs';
import { createDoctor } from './ai/doctor.mjs';

export function createSession(options) {
  const opts = options || {};
  const engineRoot = opts.engineRoot;
  const paths = enginePaths(engineRoot);
  const events = [];
  const listeners = new Set();
  const ai = opts.ai || null;
  const clientId = opts.clientId || 'default';

  let run = null;
  let lastArgs = null;
  let stopped = false;
  let stopWatcher = null;
  const jobState = { running: false, stopped: false, exitCode: null, mode: '', startedAt: '', maxMessages: 0, output: [] };

  function emit(event) {
    events.push(event);
    if (events.length > 500) events.shift();
    for (const fn of listeners) {
      try { fn(event); } catch (error) { void error; }
    }
  }

  function readConfig() {
    try {
      return JSON.parse(readFileSync(paths.config, 'utf8').replace(/^\uFEFF/, ''));
    } catch {
      return {};
    }
  }

  function writeConfig(config, before) {
    if (before) {
      try {
        const backup = join(paths.root, 'config', 'config.backup-' + Date.now() + '.json');
        writeFileSync(backup, JSON.stringify(before, null, 2), 'utf8');
      } catch (error) { void error; }
    }
    const tmp = paths.config + '.tmp';
    writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8');
    renameSync(tmp, paths.config);
  }

  function addSuppressed(email) {
    const dir = join(paths.state, clientId);
    mkdirSync(dir, { recursive: true });
    const file = join(dir, 'suppressed.json');
    let list = [];
    if (existsSync(file)) {
      try {
        const raw = JSON.parse(readFileSync(file, 'utf8'));
        list = Array.isArray(raw.Suppressed) ? raw.Suppressed : [];
      } catch (error) { void error; }
    }
    if (list.indexOf(email) < 0) list.push(email);
    writeFileSync(file, JSON.stringify({ Suppressed: list }, null, 2), 'utf8');
  }

  function stop(reason) {
    stopped = true;
    jobState.running = false;
    jobState.stopped = true;
    if (run) { run.stop(); run = null; }
    emit({ type: 'run', state: 'stopped', reason: reason || 'stopped by the operator' });
  }

  function restart(delaySeconds) {
    if (!lastArgs) return false;
    if (run) { run.stop(); run = null; }
    const args = Object.assign({}, lastArgs, { resume: true });
    emit({ type: 'run', state: 'restarting', delaySeconds: delaySeconds || 0 });
    start(args);
    return true;
  }

  function rotateProxy() {
    const config = readConfig();
    config.proxy = config.proxy || {};
    config.proxy.rotationEvery = Math.max(1, Number(config.proxy.rotationEvery || 150) - 1);
    writeConfig(config, null);
    emit({ type: 'action', action: 'rotate_proxy', detail: 'rotation window lowered by one message' });
  }

  function switchAccount(index) {
    const config = readConfig();
    const accounts = config.smtp && config.smtp.accounts ? config.smtp.accounts : [];
    if (!accounts.length) return;
    const chosen = accounts[Number(index) % accounts.length];
    config.smtp = config.smtp || {};
    config.smtp.username = chosen.username;
    config.smtp.provider = chosen.provider || config.smtp.provider;
    config.smtp.passwordEnv = chosen.passwordEnv || config.smtp.passwordEnv;
    config.message = config.message || {};
    config.message.fromEmail = chosen.username;
    config.message.replyTo = chosen.username;
    writeConfig(config, null);
    emit({ type: 'action', action: 'switch_account', detail: 'now using ' + chosen.username });
  }

  function switchVariant(index) {
    const config = readConfig();
    const variants = config.message && config.message.variants ? config.message.variants : [];
    if (variants.length < 2) return;
    const chosen = variants[Number(index) % variants.length];
    config.message = config.message || {};
    if (chosen.subject) config.message.subject = chosen.subject;
    if (chosen.templatePath) config.message.templatePath = chosen.templatePath;
    if (chosen.landingUrl) config.message.landingUrl = chosen.landingUrl;
    writeConfig(config, null);
    emit({ type: 'action', action: 'switch_variant', detail: 'now using ' + (chosen.id || chosen.subject || 'creative') });
  }

  const doctor = createDoctor({
    engine: {
      readConfig: readConfig,
      writeConfig: writeConfig,
      addSuppressed: addSuppressed,
      restart: restart,
      stop: stop,
      rotateProxy: rotateProxy,
      switchAccount: switchAccount,
      switchVariant: switchVariant
    },
    ai: ai,
    logDir: opts.logDir || join(paths.logs, clientId)
  });

  function watchRunLog(logDir, onRecord) {
    let file = '';
    let offset = 0;
    const tick = function () {
      let latest = '';
      try {
        const files = readdirSync(logDir).filter(function (f) { return f.startsWith('run-') && f.endsWith('.jsonl'); }).sort();
        latest = files.length ? join(logDir, files[files.length - 1]) : '';
      } catch (error) { void error; }
      if (!latest) return;
      if (latest !== file) { file = latest; offset = 0; }
      try {
        const stat = statSync(file);
        if (stat.size <= offset) return;
        const fd = openSync(file, 'r');
        const buffer = Buffer.alloc(stat.size - offset);
        readSync(fd, buffer, 0, buffer.length, offset);
        closeSync(fd);
        offset = stat.size;
        for (const line of buffer.toString('utf8').split(/\r?\n/)) {
          if (!line.trim()) continue;
          let record = null;
          try { record = JSON.parse(line); } catch (error) { void error; }
          if (record) onRecord(record);
        }
      } catch (error) { void error; }
    };
    const timer = setInterval(tick, 400);
    if (timer.unref) timer.unref();
    return function () { clearInterval(timer); };
  }

  function start(args) {
    stopped = false;
    lastArgs = Object.assign({}, args);
    jobState.running = true;
    jobState.stopped = false;
    jobState.exitCode = null;
    jobState.mode = args.dryRun ? 'dry' : 'send';
    jobState.startedAt = new Date().toISOString();
    jobState.maxMessages = Number(args.maxMessages || 0);
    jobState.output = [];
    emit({ type: 'run', state: 'started', args: { clientId: args.clientId, dryRun: !!args.dryRun, resume: !!args.resume } });
    run = runEngine({
      engineRoot: engineRoot,
      clientId: args.clientId,
      clientPath: args.clientPath,
      recipientsPath: args.recipientsPath,
      configPath: args.configPath,
      dryRun: args.dryRun,
      resume: args.resume,
      maxMessages: args.maxMessages || 0,
      batchSize: args.batchSize || 0,
      skipUrlChecks: !!args.skipUrlChecks,
      env: args.env || {},
      onLine: function (text) {
        emit({ type: 'line', text: text, at: new Date().toISOString() });
        jobState.output.push(text);
        if (jobState.output.length > 400) jobState.output.shift();
      },
      onExit: function (code) {
        emit({ type: 'run', state: 'finished', exitCode: code });
        jobState.running = false;
        jobState.exitCode = code;
        run = null;
      }
    });
    if (stopWatcher) stopWatcher();
    stopWatcher = watchRunLog(paths.logs, function (record) {
      if (String(record.lvl || '').toUpperCase() !== 'ERROR') return;
      const data = record.data || {};
      emit({ type: 'engine-error', message: String(record.msg || ''), code: String(data.code || '') });
      doctor.observe({ code: String(data.code || ''), text: String(record.msg || '') }).catch(function (error) {
        emit({ type: 'doctor-error', error: String((error && error.message) || error) });
      });
    });
    return run;
  }

  return {
    engineRoot: engineRoot,
    paths: paths,
    clientId: clientId,
    doctor: doctor,
    events: events,
    start: start,
    stop: stop,
    restart: restart,
    readConfig: readConfig,
    writeConfig: writeConfig,
    addSuppressed: addSuppressed,
    isRunning: function () { return !!run; },
    jobInfo: function () { return { running: jobState.running, stopped: jobState.stopped, exitCode: jobState.exitCode, mode: jobState.mode, startedAt: jobState.startedAt, maxMessages: jobState.maxMessages, output: jobState.output.slice() }; },
    on: function (fn) { listeners.add(fn); return function () { listeners.delete(fn); }; },
    emit: emit
  };
}
