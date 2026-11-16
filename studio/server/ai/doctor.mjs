import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { classifyError, ACTION } from './rules.mjs';
import { guardCheck } from './guard.mjs';

export const AI_ACTIONS = [
  ACTION.REDUCE_DELAY,
  ACTION.SHRINK_BATCH,
  ACTION.ROTATE_PROXY,
  ACTION.SWITCH_ACCOUNT,
  ACTION.SWITCH_VARIANT,
  ACTION.SUPPRESS,
  ACTION.BACKOFF,
  ACTION.FIX_FROM_EMAIL,
  ACTION.SWITCH_TLS,
  ACTION.HALT
];

const SYSTEM = 'You are a deliverability engineer for a Windows SMTP bulk sender. You may only choose one action from the allowed list. Reply with one JSON object and nothing else.';

export const DOCTOR_LIMITS = {
  cooldownMs: 90000,
  maxRepeats: 3
};

export function parseJsonReply(raw) {
  const tick = String.fromCharCode(96);
  let text = String(raw || '').split(tick + tick + tick).join('');
  text = text.trim();
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
}

export function extractEmail(text) {
  const m = String(text || '').match(/([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})/);
  return m ? m[1].toLowerCase() : '';
}

export function createDoctor(options) {
  const opts = options || {};
  const engine = opts.engine || {};
  const ai = opts.ai || null;
  const logDir = opts.logDir || null;
  const decisions = [];
  const recent = new Map();
  let haltAttempts = 0;
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');

  function log(record) {
    const entry = Object.assign({ at: new Date().toISOString() }, record);
    decisions.push(entry);
    if (logDir) {
      try {
        mkdirSync(logDir, { recursive: true });
        appendFileSync(join(logDir, 'ai-' + stamp + '.jsonl'), JSON.stringify(entry) + '\n');
      } catch (error) { void error; }
    }
    return entry;
  }

  function context() {
    let config = {};
    try { config = engine.readConfig ? engine.readConfig() : {}; } catch (error) { void error; }
    const message = config.message || {};
    const smtp = config.smtp || {};
    const batch = config.batch || {};
    const accounts = Array.isArray(smtp.accounts) && smtp.accounts.length
      ? smtp.accounts
      : (smtp.username ? [{ username: smtp.username }] : []);
    return {
      delayMs: Number(batch.delayBetweenMessagesMs || 1200),
      batchSize: Number(batch.size || 150),
      smtpUsername: String(smtp.username || ''),
      accounts: accounts,
      variants: Array.isArray(message.variants) ? message.variants : [],
      allowedDomains: Array.isArray(message.allowedDomains) ? message.allowedDomains : [],
      fromEmail: String(message.fromEmail || ''),
      haltAttempts: haltAttempts
    };
  }

  async function askAi(classification, text) {
    if (!ai || typeof ai.call !== 'function') return null;
    const ctx = context();
    const prompt = [
      'Allowed actions: ' + AI_ACTIONS.join(', '),
      'Failure text: ' + String(text || '').slice(0, 800),
      'Current pacing: delay=' + ctx.delayMs + 'ms batch=' + ctx.batchSize,
      'Authenticated account: ' + ctx.smtpUsername,
      'Creatives available: ' + ctx.variants.length,
      'Answer with JSON only: {"diagnosis":"short","action":"one allowed action","params":{},"confidence":0.0-1.0}'
    ].join('\n');

    let raw = '';
    try {
      raw = await ai.call({ system: SYSTEM, prompt: prompt });
    } catch (error) {
      log({ type: 'ai-error', error: String((error && error.message) || error) });
      return null;
    }

    const parsed = parseJsonReply(raw);
    if (!parsed || !parsed.action || AI_ACTIONS.indexOf(parsed.action) < 0) {
      log({ type: 'ai-rejected', raw: String(raw).slice(0, 400) });
      return null;
    }
    const confidence = Number(parsed.confidence);
    if (Number.isFinite(confidence) && confidence < 0.5) {
      log({ type: 'ai-low-confidence', action: parsed.action, confidence: confidence });
      return null;
    }
    return {
      source: 'ai',
      action: parsed.action,
      params: parsed.params || {},
      diagnosis: String(parsed.diagnosis || classification.klass),
      confidence: Number.isFinite(confidence) ? confidence : 0.5
    };
  }

  function apply(guard, text) {
    const action = guard.action;
    const params = guard.params || {};

    if (action === ACTION.REDUCE_DELAY || action === ACTION.SHRINK_BATCH ||
        action === ACTION.SWITCH_TLS || action === ACTION.FIX_FROM_EMAIL) {
      if (!engine.readConfig || !engine.writeConfig) return { ok: false, detail: 'the engine cannot edit the config' };
      const config = engine.readConfig();
      const before = JSON.parse(JSON.stringify(config));
      config.batch = config.batch || {};
      config.smtp = config.smtp || {};
      config.message = config.message || {};
      if (action === ACTION.REDUCE_DELAY) config.batch.delayBetweenMessagesMs = params.delayMs;
      if (action === ACTION.SHRINK_BATCH) config.batch.size = params.batchSize;
      if (action === ACTION.SWITCH_TLS) {
        config.smtp.encryption = params.encryption;
        config.smtp.port = params.port;
      }
      if (action === ACTION.FIX_FROM_EMAIL) {
        config.message.fromEmail = params.fromEmail;
        config.message.replyTo = params.fromEmail;
      }
      engine.writeConfig(config, before);
      const restarted = engine.restart ? engine.restart() : false;
      return { ok: true, detail: 'config updated, restart=' + restarted };
    }

    if (action === ACTION.SUPPRESS) {
      const email = params.email || extractEmail(text);
      if (!email) return { ok: false, detail: 'no address found to suppress' };
      if (engine.addSuppressed) engine.addSuppressed(email);
      const restarted = engine.restart ? engine.restart() : false;
      return { ok: true, detail: 'suppressed ' + email + ', restart=' + restarted };
    }

    if (action === ACTION.ROTATE_PROXY) {
      if (engine.rotateProxy) engine.rotateProxy();
      return { ok: true, detail: 'egress rotation requested' };
    }

    if (action === ACTION.SWITCH_ACCOUNT) {
      if (engine.switchAccount) engine.switchAccount(params.accountIndex);
      return { ok: true, detail: 'switched account' };
    }

    if (action === ACTION.SWITCH_VARIANT) {
      if (engine.switchVariant) engine.switchVariant(params.variantIndex);
      return { ok: true, detail: 'switched creative' };
    }

    if (action === ACTION.BACKOFF) {
      const restarted = engine.restart ? engine.restart(params.seconds) : false;
      return { ok: true, detail: 'paused ' + params.seconds + 's, restart=' + restarted };
    }

    if (action === ACTION.HALT) {
      haltAttempts += 1;
      if (engine.stop) engine.stop('ai-doctor');
      return { ok: true, detail: 'run halted by the doctor' };
    }

    if (action === ACTION.ESCALATE) {
      return { ok: true, detail: 'escalated to the operator' };
    }

    return { ok: false, detail: 'no handler for ' + action };
  }

  async function observe(event) {
    const text = String((event && event.text) || '');
    const code = String((event && event.code) || '');
    const classification = classifyError({ code: code, text: text });
    if (!classification || classification.action === ACTION.NONE) return null;

    let choice = {
      source: 'rules',
      action: classification.action,
      params: classification.params || {},
      diagnosis: classification.klass,
      confidence: 1
    };

    if (classification.action === ACTION.ESCALATE || classification.klass === 'unknown') {
      const aiChoice = await askAi(classification, text);
      if (!aiChoice) {
        log({ type: 'unclassified', code: code, text: text.slice(0, 400) });
        return null;
      }
      choice = aiChoice;
    }

    const guard = guardCheck({ action: choice.action, params: choice.params }, context());
    if (!guard.allowed) {
      log({ type: 'blocked', action: choice.action, reason: guard.reason, source: choice.source, text: text.slice(0, 300) });
      return { applied: false, action: choice.action, reason: guard.reason };
    }

    // The same failure must not trigger the same repair over and over: a
    // resumed run reports the same recipient again, and without this guard
    // the doctor would restart the run in a loop.
    const key = guard.action + '|' + (classification.code || 'unknown');
    const now = Date.now();
    const seen = recent.get(key);
    if (seen && (now - seen.at) < DOCTOR_LIMITS.cooldownMs) {
      seen.count += 1;
      if (seen.count >= DOCTOR_LIMITS.maxRepeats) {
        const halt = guardCheck({ action: ACTION.HALT, params: {} }, context());
        if (halt.allowed) {
          const halted = apply(halt, text);
          log({
            type: 'halted-after-repeats', action: guard.action, key: key, count: seen.count,
            text: text.slice(0, 300), detail: halted.detail,
            reason: 'the same failure survived ' + seen.count + ' repairs: the run was stopped for the operator'
          });
          return { applied: false, action: guard.action, reason: 'repeated failure: the run was stopped' };
        }
      }
      log({ type: 'cooldown', action: guard.action, key: key, count: seen.count, text: text.slice(0, 300), reason: 'the same repair is on cooldown' });
      return { applied: false, action: guard.action, reason: 'cooldown' };
    }
    recent.set(key, { at: now, count: 1 });

    const result = apply(guard, text);
    log({
      type: result.ok ? 'applied' : 'failed',
      action: guard.action,
      params: guard.params,
      reason: guard.reason,
      diagnosis: choice.diagnosis,
      source: choice.source,
      confidence: choice.confidence,
      text: text.slice(0, 300),
      detail: result.detail
    });
    return Object.assign({ applied: !!result.ok, action: guard.action }, result);
  }

  return {
    decisions: decisions,
    observe: observe,
    context: context,
    stop: function () { if (engine.stop) engine.stop('doctor-stop'); }
  };
}
