import { spawn } from 'node:child_process';
import { enginePaths } from './engine.mjs';

export function runEngine(options) {
  const opts = options || {};
  const paths = enginePaths(opts.engineRoot);
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', paths.sendScript];

  if (opts.configPath) args.push('-ConfigPath', opts.configPath);
  if (opts.clientPath) args.push('-ClientPath', opts.clientPath);
  if (opts.clientId) args.push('-ClientId', opts.clientId);
  if (opts.recipientsPath) args.push('-RecipientsPath', opts.recipientsPath);
  if (opts.dryRun) args.push('-DryRun');
  if (opts.resume) args.push('-Resume');
  if (opts.skipUrlChecks) args.push('-SkipUrlChecks');
  if (opts.maxMessages > 0) args.push('-MaxMessages', String(opts.maxMessages));
  if (opts.batchSize > 0) args.push('-BatchSize', String(opts.batchSize));

  const env = Object.assign({}, process.env, opts.env || {});
  const child = spawn('powershell.exe', args, {
    cwd: opts.engineRoot,
    env: env,
    windowsHide: true
  });

  let buffer = '';
  const onLine = typeof opts.onLine === 'function' ? opts.onLine : function () {};
  const onExit = typeof opts.onExit === 'function' ? opts.onExit : function () {};

  function handle(chunk) {
    buffer += chunk.toString();
    let index = buffer.indexOf('\n');
    while (index >= 0) {
      const line = buffer.slice(0, index).replace(/\r$/, '');
      buffer = buffer.slice(index + 1);
      if (line.trim()) onLine(line);
      index = buffer.indexOf('\n');
    }
  }

  child.stdout.on('data', handle);
  child.stderr.on('data', handle);
  child.on('close', function (code) { onExit(code); });

  return {
    child: child,
    args: args,
    isRunning: function () { return child.exitCode === null; },
    stop: function () {
      try { child.kill(); } catch (error) { void error; }
    }
  };
}
