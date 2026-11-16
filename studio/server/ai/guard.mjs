import { ACTION } from './rules.mjs';

export const GUARD_LIMITS = {
  minDelayMs: 300,
  minBatchSize: 20,
  maxRatePerHour: 50,
  maxHaltAttempts: 3,
  maxBackoffSeconds: 900,
  minBackoffSeconds: 15
};

const FORBIDDEN = [
  'disable_unsubscribe',
  'remove_list_unsubscribe',
  'set_consent_basis',
  'bypass_domain_filter',
  'edit_protected_file',
  'bypass_integrity',
  'raise_rate',
  'forge_headers',
  'rotate_domain',
  'send_to_blocked_domain'
];

function clamp(value, low, high) {
  const n = Number(value);
  if (!Number.isFinite(n)) return low;
  return Math.min(high, Math.max(low, n));
}

export function guardCheck(input, ctx) {
  const action = String((input && input.action) || '');
  const params = (input && input.params) || {};
  const context = ctx || {};

  if (FORBIDDEN.indexOf(action) >= 0) {
    return { allowed: false, reason: 'action ' + action + ' is forbidden by policy' };
  }

  switch (action) {
    case ACTION.REDUCE_DELAY: {
      const current = Number(context.delayMs || 1200);
      const factor = Number(params.factor || 0.7);
      const next = clamp(Math.round(current * factor), GUARD_LIMITS.minDelayMs, 60000);
      return { allowed: true, action: action, params: { delayMs: next }, reason: 'pacing lowered to ' + next + 'ms' };
    }
    case ACTION.SHRINK_BATCH: {
      const current = Number(context.batchSize || 150);
      const factor = Number(params.factor || 0.5);
      const next = clamp(Math.round(current * factor), GUARD_LIMITS.minBatchSize, 150);
      return { allowed: true, action: action, params: { batchSize: next }, reason: 'batch lowered to ' + next };
    }
    case ACTION.BACKOFF: {
      const seconds = clamp(params.seconds || 30, GUARD_LIMITS.minBackoffSeconds, GUARD_LIMITS.maxBackoffSeconds);
      return { allowed: true, action: action, params: { seconds: seconds }, reason: 'paused ' + seconds + 's' };
    }
    case ACTION.FIX_FROM_EMAIL: {
      const account = String(context.smtpUsername || '');
      const wanted = String(params.fromEmail || '');
      if (!account) return { allowed: false, reason: 'no authenticated account to align with' };
      if (wanted && wanted.toLowerCase() !== account.toLowerCase()) {
        return { allowed: false, reason: 'fromEmail must equal the authenticated account' };
      }
      return { allowed: true, action: action, params: { fromEmail: account }, reason: 'sender aligned with the authenticated account' };
    }
    case ACTION.SWITCH_ACCOUNT: {
      const accounts = context.accounts || [];
      if (accounts.length < 2) return { allowed: false, reason: 'the client profile has only one SMTP account' };
      const index = clamp(params.accountIndex || 1, 0, accounts.length - 1);
      return { allowed: true, action: action, params: { accountIndex: index }, reason: 'moving to account ' + index };
    }
    case ACTION.SWITCH_VARIANT: {
      const variants = context.variants || [];
      if (variants.length < 2) return { allowed: false, reason: 'the client profile has only one creative' };
      const index = clamp(params.variantIndex || 1, 0, variants.length - 1);
      return { allowed: true, action: action, params: { variantIndex: index }, reason: 'moving to creative ' + index };
    }
    case ACTION.SWITCH_TLS:
      return { allowed: true, action: action, params: { encryption: 'ssl', port: 465 }, reason: 'switching to implicit TLS' };
    case ACTION.ROTATE_PROXY:
      return { allowed: true, action: action, params: {}, reason: 'rotating the egress endpoint' };
    case ACTION.SUPPRESS:
      return { allowed: true, action: action, params: { email: String(params.email || '') }, reason: 'suppressing the address' };
    case ACTION.HALT: {
      const attempts = Number(context.haltAttempts || 0);
      if (attempts >= GUARD_LIMITS.maxHaltAttempts) {
        return { allowed: false, reason: 'halt attempt limit reached' };
      }
      return { allowed: true, action: action, params: {}, reason: 'stopping the run' };
    }
    case ACTION.ESCALATE:
      return { allowed: true, action: action, params: {}, reason: 'needs a human decision' };
    case ACTION.NONE:
      return { allowed: false, reason: 'no action requested' };
    default:
      return { allowed: false, reason: 'unknown action ' + action };
  }
}
